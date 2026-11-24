#!/bin/bash
# Publish TARGET under PUBLISH_TAGS (${REGISTRY}/<image>:<version> and
# :<version>-${TAG_SUFFIX}) and record the digests in
# ${WORK_DIR}/digests.txt. Run only after scripts/verify-image.sh passed.
#   MODE=build: push LOCAL_IMAGE (linux/amd64), unless the published image
#               already has the same build key (scripts/lib.sh build_key: same
#               sources) - then the tags stay where they are. FORCE_PUSH=1
#               always pushes.
#   MODE=copy:  copy SOURCE_IMAGE unchanged (every platform, same digest).
# Needs `docker login` to the registry.
source "$(dirname "$0")/lib.sh"
[[ -n "${TARGET:-}" ]] || die "TARGET is not set (make targets)"
command -v jq >/dev/null || die "jq not found"

mkdir -p "${WORK_DIR}"
digests="${WORK_DIR}/digests.txt"
: > "${digests}.tmp"

pushed=0
if [[ "${MODE}" == build ]]; then
    docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1 || die "${LOCAL_IMAGE} is not built (make build TARGET=${TARGET})"
    label() { docker image inspect --format "{{index .Config.Labels \"$1\"}}" "${LOCAL_IMAGE}"; }
    key="$(label "${BUILD_KEY_LABEL}")"
    [[ -n "${key}" ]] || die "${LOCAL_IMAGE} has no ${BUILD_KEY_LABEL} label"
    keep=""
    if [[ "${FORCE_PUSH:-0}" != 1 && -n "$(remote_digest "${PUBLISH_TAGS[0]}")" ]] \
        && [[ "$(remote_label "${PUBLISH_TAGS[0]}" "${BUILD_KEY_LABEL}")" == "${key}" ]]; then
        keep="same build key ${key:0:12}"
    fi
    if [[ -n "${keep}" ]]; then
        log "${PUBLISH_TAGS[0]} is kept (${keep}); FORCE_PUSH=1 replaces it"
        want="$(remote_digest "${PUBLISH_TAGS[0]}")"
    else
        for tag in "${PUBLISH_TAGS[@]}"; do
            log "push ${tag}"
            docker tag "${LOCAL_IMAGE}" "${tag}"
            docker push -q "${tag}" >/dev/null
        done
        pushed=1
        want=""
    fi
else
    want="${SOURCE_IMAGE##*@}"
    args=()
    for tag in "${PUBLISH_TAGS[@]}"; do args+=(--tag "${tag}"); done
    log "copy ${SOURCE_IMAGE} -> ${PUBLISH_TAGS[*]}"
    docker buildx imagetools create --prefer-index=false "${args[@]}" "${SOURCE_IMAGE}"
fi

first=""
for tag in "${PUBLISH_TAGS[@]}"; do
    digest="$(remote_digest "${tag}")"
    [[ "${digest}" == sha256:* ]] || die "cannot read the digest of ${tag}"
    [[ -z "${want}" || "${digest}" == "${want}" ]] || die "${tag} has digest ${digest}, want ${want} (copy of ${SOURCE_IMAGE})"
    [[ -z "${first}" || "${digest}" == "${first}" ]] || die "${tag} has digest ${digest}, but ${PUBLISH_TAGS[0]} has ${first}"
    if [[ "${pushed}" == 1 ]]; then
        # The pushed manifest must be the verified local image.
        docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_IMAGE}" \
            | grep -qxF "${IMAGE_REPO}@${digest}" \
            || die "${tag} (${digest}) is not the verified ${LOCAL_IMAGE}"
    fi
    first="${digest}"
    echo "${tag} ${digest}" | tee -a "${digests}.tmp"
done
mv "${digests}.tmp" "${digests}"
