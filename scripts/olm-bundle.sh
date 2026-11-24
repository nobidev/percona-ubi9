#!/bin/bash
# Build, verify and publish the OLM bundles of bundles/<package>/<version>.env.
#
#   olm-bundle.sh build [BUNDLE...]   extract the upstream bundle; MODE=rewrite:
#                                     replace IMAGE_FROM by IMAGE_TO, check the
#                                     change, build a local bundle image
#   olm-bundle.sh check [BUNDLE...]   static checks only (settings, IMAGE_TARGET exists)
#   olm-bundle.sh push  [BUNDLE...]   publish to ${OLM_REGISTRY}/<package>-bundle:v<version>
#                                     (unchanged content is not pushed again) and
#                                     record the digests in ${OLM_DIR}/bundles.txt
#
# BUNDLE is <package>/<version>; default: every bundle.
# REQUIRE_PUBLISHED_IMAGES=1 (default) makes `push` fail unless every IMAGE_TO
# already exists in the registry (set 0 on pull requests).
source "$(dirname "$0")/lib.sh"
command -v jq >/dev/null || die "jq not found"

action="${1:-}"
shift || true
[[ "${action}" =~ ^(build|push|check)$ ]] || die "usage: $0 build|push|check [BUNDLE...]"
if [[ $# -eq 0 ]]; then
    mapfile -t bundles < <(list_bundles)
else
    bundles=("$@")
fi

# sha256 of a directory tree (names, modes and contents; no timestamps/owners).
tree_hash() {
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -C "$1" . | sha256sum | cut -d' ' -f1
}

local_bundle_image() { echo "localhost/percona-ubi9/${PACKAGE}-bundle:v${BUNDLE_VERSION}"; }

build_one() {
    local up="${BUNDLE_WORK}/upstream" out="${BUNDLE_WORK}/bundle" ctr n back
    rm -rf -- "${BUNDLE_WORK:?}"
    mkdir -p "${up}" "${out}"
    log "${PACKAGE}/${BUNDLE_VERSION}: upstream bundle ${UPSTREAM_BUNDLE}"
    docker pull -q "${UPSTREAM_BUNDLE}" >/dev/null
    ctr="$(docker create "${UPSTREAM_BUNDLE}" /none)"
    docker cp -q "${ctr}:/manifests" "${up}/"
    docker cp -q "${ctr}:/metadata" "${up}/"
    docker container rm -f "${ctr}" >/dev/null
    [[ -f "${up}/metadata/annotations.yaml" ]] || die "${PACKAGE}/${BUNDLE_VERSION}: no metadata/annotations.yaml in ${UPSTREAM_BUNDLE}"
    grep -qE "operators\.operatorframework\.io\.bundle\.package\.v1: *'?${PACKAGE}'?$" "${up}/metadata/annotations.yaml" \
        || die "${PACKAGE}/${BUNDLE_VERSION}: ${UPSTREAM_BUNDLE} is not a bundle of package ${PACKAGE}"
    if [[ "${MODE}" == copy ]]; then
        log "${PACKAGE}/${BUNDLE_VERSION}: MODE=copy, nothing to build"
        return 0
    fi

    cp -a "${up}/." "${out}/"
    # Replace IMAGE_FROM at reference boundaries; no other reference to the
    # upstream image repository may be left (scripts/olm-rewrite.py).
    n="$(python3 -I "${ROOT_DIR}/scripts/olm-rewrite.py" rewrite "${out}" "${IMAGE_FROM}" "${IMAGE_TO}")" \
        || die "${PACKAGE}/${BUNDLE_VERSION}: unexpected references to the upstream operator image (see above)"
    [[ "${n}" -gt 0 ]] || die "${PACKAGE}/${BUNDLE_VERSION}: ${IMAGE_FROM} does not occur in the bundle"
    # The only change must be the image reference: undoing it gives the upstream bundle.
    back="${BUNDLE_WORK}/reverted"
    cp -a "${out}" "${back}"
    python3 -I "${ROOT_DIR}/scripts/olm-rewrite.py" revert "${back}" "${IMAGE_TO}" "${IMAGE_FROM}"
    diff -r "${up}" "${back}" >/dev/null || die "${PACKAGE}/${BUNDLE_VERSION}: the bundle differs from upstream in more than ${IMAGE_FROM}"
    rm -rf -- "${back:?}"
    grep -qF -e "image: ${IMAGE_TO}" -e "image: \"${IMAGE_TO}\"" -e "image: '${IMAGE_TO}'" \
        "${out}"/manifests/*.clusterserviceversion.yaml \
        || die "${PACKAGE}/${BUNDLE_VERSION}: the CSV deployment does not use ${IMAGE_TO}"
    log "${PACKAGE}/${BUNDLE_VERSION}: ${n} x ${IMAGE_FROM} -> ${IMAGE_TO}; nothing else changed"

    # Bundle image: the upstream layout, the bundle annotations as labels.
    {
        echo "FROM scratch"
        echo "COPY manifests /manifests/"
        echo "COPY metadata /metadata/"
        python3 -I "${ROOT_DIR}/scripts/olm-rewrite.py" labels "${out}/metadata/annotations.yaml" \
            || die "${PACKAGE}/${BUNDLE_VERSION}: cannot read the bundle annotations"
        echo "LABEL org.opencontainers.image.source=\"${SOURCE_URL}\""
        echo "LABEL io.nobidev.percona-ubi9.upstream=\"${UPSTREAM_BUNDLE}\""
    } > "${out}/Dockerfile"
    grep -q 'operators.operatorframework.io.bundle.package.v1=' "${out}/Dockerfile" \
        || die "${PACKAGE}/${BUNDLE_VERSION}: cannot read the bundle annotations"
    local hash
    hash="$(tree_hash "${out}")"
    echo "${hash}" > "${BUNDLE_WORK}/content"
    docker build -q --label "${CONTENT_LABEL}=${hash}" -t "$(local_bundle_image)" "${out}" >/dev/null
    log "${PACKAGE}/${BUNDLE_VERSION}: built $(local_bundle_image) (content ${hash:0:12})"
}

push_one() {
    local digest want hash
    mkdir -p "${OLM_DIR}"
    if [[ "${MODE}" == copy ]]; then
        want="${UPSTREAM_BUNDLE##*@}"
        if [[ "$(remote_digest "${BUNDLE_IMAGE}")" != "${want}" ]]; then
            log "copy ${UPSTREAM_BUNDLE} -> ${BUNDLE_IMAGE}"
            docker buildx imagetools create --prefer-index=false --tag "${BUNDLE_IMAGE}" "${UPSTREAM_BUNDLE}"
        else
            log "${BUNDLE_IMAGE} already is ${want}"
        fi
        digest="$(remote_digest "${BUNDLE_IMAGE}")"
        [[ "${digest}" == "${want}" ]] || die "${BUNDLE_IMAGE} has digest '${digest}', want ${want}"
    else
        [[ -f "${BUNDLE_WORK}/content" ]] || die "${PACKAGE}/${BUNDLE_VERSION} is not built (olm-bundle.sh build)"
        if [[ "${REQUIRE_PUBLISHED_IMAGES:-1}" == 1 ]]; then
            [[ -n "$(remote_digest "${IMAGE_TO}")" ]] \
                || die "${PACKAGE}/${BUNDLE_VERSION}: ${IMAGE_TO} is not published (make push TARGET=${IMAGE_TARGET})"
        fi
        hash="$(cat "${BUNDLE_WORK}/content")"
        if [[ "$(remote_label "${BUNDLE_IMAGE}" "${CONTENT_LABEL}")" == "${hash}" ]]; then
            log "${BUNDLE_IMAGE} has the same content (${hash:0:12}); not pushed again"
        else
            log "push ${BUNDLE_IMAGE}"
            docker tag "$(local_bundle_image)" "${BUNDLE_IMAGE}"
            docker push -q "${BUNDLE_IMAGE}" >/dev/null
        fi
        digest="$(remote_digest "${BUNDLE_IMAGE}")"
        [[ "${digest}" == sha256:* ]] || die "cannot read the digest of ${BUNDLE_IMAGE}"
        [[ "$(remote_label "${BUNDLE_IMAGE}" "${CONTENT_LABEL}")" == "${hash}" ]] \
            || die "${BUNDLE_IMAGE} does not carry content ${hash}"
    fi
    echo "${PACKAGE}/${BUNDLE_VERSION} ${BUNDLE_IMAGE%:*}@${digest}" | tee -a "${OLM_DIR}/bundles.txt.tmp"
}

mkdir -p "${OLM_DIR}"
if [[ "${action}" == push ]]; then
    : > "${OLM_DIR}/bundles.txt.tmp"
fi
for b in "${bundles[@]}"; do
    (
        load_bundle "${b}"
        case "${action}" in
            build) build_one ;;
            push) push_one ;;
            check) log "${PACKAGE}/${BUNDLE_VERSION}: ${MODE} of ${UPSTREAM_BUNDLE}${IMAGE_TO:+, ${IMAGE_FROM} -> ${IMAGE_TO}}" ;;
        esac
    )
done
if [[ "${action}" == push ]]; then
    mv "${OLM_DIR}/bundles.txt.tmp" "${OLM_DIR}/bundles.txt"
fi
log "bundles ${action}: ${bundles[*]}"
