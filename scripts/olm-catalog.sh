#!/bin/bash
# Build, verify and publish the OLM catalog of the published bundles.
#
#   olm-catalog.sh build    render the upstream index packages and our bundles
#                           (${OLM_DIR}/bundles.txt from `olm-bundle.sh push`)
#                           with opm, assemble the FBC (scripts/olm-fbc.py),
#                           `opm validate` it and build the catalog image
#   olm-catalog.sh verify   the catalog image runs on an x86-64-v2 CPU (ISA scan,
#                           opm under qemu -cpu ${QEMU_CPU}) and serves the
#                           catalog over gRPC as an arbitrary non-root user
#   olm-catalog.sh push     publish ${OLM_REGISTRY}/${CATALOG_NAME}:latest and
#                           :<date>-<content hash> (unchanged content is not
#                           pushed again); digest in ${OLM_DIR}/catalog.txt
source "$(dirname "$0")/lib.sh"
command -v jq >/dev/null || die "jq not found"

LOCAL_CATALOG=localhost/percona-ubi9/${CATALOG_NAME}:local
CATALOG_IMAGE="${OLM_REGISTRY}/${CATALOG_NAME}"

tree_hash() {
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - -C "$1" . | sha256sum | cut -d' ' -f1
}

build() {
    [[ -s "${OLM_DIR}/bundles.txt" ]] || die "no ${OLM_DIR}/bundles.txt (olm-bundle.sh build && olm-bundle.sh push)"
    local work="${OLM_DIR}/catalog-work" render_args=() target ref package packages
    rm -rf -- "${work:?}" "${OLM_DIR:?}/catalog"
    rm -f -- "${OLM_DIR}/operators.txt" "${OLM_DIR}/catalog.content"
    mkdir -p "${work}/index" "${work}/upstream" "${work}/rendered"
    # opm talks plain HTTP to a local (pull request) registry.
    [[ "${OLM_REGISTRY}" != localhost* && "${OLM_REGISTRY}" != 127.0.0.1* ]] || render_args+=(--use-http)

    # Specs for olm-fbc.py, in bundles.txt order.
    : > "${work}/bundles.spec"
    while read -r target ref; do
        (
            load_bundle "${target}"
            [[ "${ref%@*}" == "${BUNDLE_IMAGE%:*}" ]] || die "${target}: bundles.txt has ${ref}, want ${BUNDLE_IMAGE%:*}@..."
            echo "${target} ${MODE} ${ref} ${UPSTREAM_BUNDLE} ${IMAGE_FROM:--} ${IMAGE_TO:--}"
        ) >> "${work}/bundles.spec"
    done < "${OLM_DIR}/bundles.txt"

    # A catalog without some of the bundles would break the Subscriptions of
    # the missing packages: bundles.txt must list every bundle.
    [[ "$(cut -d' ' -f1 "${OLM_DIR}/bundles.txt" | sort)" == "$(list_bundles | sort)" ]] \
        || die "${OLM_DIR}/bundles.txt does not list every bundle (run olm-bundle.sh push without arguments)"
    mapfile -t packages < <(cut -d/ -f1 "${work}/bundles.spec" | sort -u)
    log "extracting the upstream packages from ${UPSTREAM_INDEX}"
    docker pull -q --platform "${PLATFORM}" "${UPSTREAM_INDEX}" >/dev/null
    local ctr
    ctr="$(docker create --platform "${PLATFORM}" "${UPSTREAM_INDEX}" /none)"
    for package in "${packages[@]}"; do
        docker cp -q "${ctr}:/configs/${package}" "${work}/index/" \
            || { docker container rm -f "${ctr}" >/dev/null; die "${package} is not in ${UPSTREAM_INDEX}"; }
    done
    docker container rm -f "${ctr}" >/dev/null

    (
        cd "${work}"
        for package in "${packages[@]}"; do
            opm_run render "index/${package}" -o json > "upstream/${package}.json"
        done
        while read -r target _ ref upstream_ref _; do
            package="${target%%/*}"
            mkdir -p "rendered/${package}"
            log "opm render ${ref}"
            opm_run render "${render_args[@]}" "${ref}" -o json > "rendered/${target}.json"
            opm_run render "${upstream_ref}" -o json > "rendered/${target}.upstream.json"
        done < bundles.spec
    )
    python3 -I "${ROOT_DIR}/scripts/olm-fbc.py" --bundles "${work}/bundles.spec" \
        --upstream "${work}/upstream" --rendered "${work}/rendered" --out "${OLM_DIR}/catalog" \
        --operators "${OLM_DIR}/operators.txt"
    (cd "${OLM_DIR}" && opm_run validate catalog) || die "opm validate failed"
    log "opm validate: OK"

    # Catalog image, as `opm generate dockerfile` writes it, plus labels. The
    # content hash covers the catalog and the Dockerfile.
    local hash
    cat > "${OLM_DIR}/catalog.Dockerfile" <<EOF
FROM ${OPM_IMAGE}
ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]
ADD catalog /configs
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]
LABEL operators.operatorframework.io.index.configs.v1=/configs
LABEL org.opencontainers.image.source="${SOURCE_URL}"
EOF
    hash="$( { tree_hash "${OLM_DIR}/catalog"; cat "${OLM_DIR}/catalog.Dockerfile"; } | sha256sum | cut -d' ' -f1)"
    echo "LABEL ${CONTENT_LABEL}=\"${hash}\"" >> "${OLM_DIR}/catalog.Dockerfile"
    echo "${hash}" > "${OLM_DIR}/catalog.content"
    docker build -q --platform "${PLATFORM}" -f "${OLM_DIR}/catalog.Dockerfile" -t "${LOCAL_CATALOG}" "${OLM_DIR}" >/dev/null
    log "built ${LOCAL_CATALOG} (content ${hash:0:12}): $(cut -d' ' -f1 "${OLM_DIR}/bundles.txt" | tr '\n' ' ')"
}

verify() {
    docker image inspect "${LOCAL_CATALOG}" >/dev/null 2>&1 || die "${LOCAL_CATALOG} is not built (olm-catalog.sh build)"
    command -v qemu-x86_64 >/dev/null || die "qemu-x86_64 not found (install qemu-user)"
    local rc=0 out
    mkdir -p "${OLM_DIR}"
    # Globals (not local): the EXIT trap, which also runs when die exits,
    # needs them after verify has returned.
    rootfs="$(mktemp -d "${OLM_DIR}/rootfs.XXXXXX")"
    ctr=""
    trap 'chmod -R u+rwX -- "${rootfs}" 2>/dev/null; rm -rf -- "${rootfs:?}"; [[ -z "${ctr}" ]] || docker container rm -f "${ctr}" >/dev/null 2>&1 || true' EXIT
    ctr="$(docker create --platform "${PLATFORM}" "${LOCAL_CATALOG}")"
    docker export "${ctr}" | tar -x -C "${rootfs}" --exclude='dev/*' || die "cannot export ${LOCAL_CATALOG}"
    docker container rm -f "${ctr}" >/dev/null
    ctr=""
    chmod -R u+rX -- "${rootfs}"
    echo "### catalog ${LOCAL_CATALOG} ($(docker image inspect --format '{{.Id}}' "${LOCAL_CATALOG}"))"

    echo "b. ISA marking of every ELF object"
    python3 -I "${ROOT_DIR}/scripts/check-isa.py" "${rootfs}" | sed 's/^/  /' || rc=1
    for bin in /bin/opm /bin/grpc_health_probe; do
        if objdump -p "${rootfs}${bin}" | grep -q NEEDED; then
            echo "  FAIL  ${bin}: dynamic (the catalog image has no glibc of its own)"
            rc=1
        else
            echo "  ok    ${bin}: static"
        fi
    done

    echo "c. execution under qemu-x86_64 -cpu ${QEMU_CPU}"
    local cmd
    for cmd in "/bin/opm version" "/bin/opm validate /configs" "/bin/grpc_health_probe -version"; do
        read -r -a argv <<< "${cmd}"
        out="$(cd "${rootfs}" && env -i PATH=/bin HOME=/nonexistent timeout -k 5 "${SMOKE_TIMEOUT}" \
            qemu-x86_64 -cpu "${QEMU_CPU}" -L "${rootfs}" -0 "${argv[0]}" "${rootfs}${argv[0]}" "${argv[@]:1}" 2>&1 < /dev/null)" && r=0 || r=$?
        if [[ "${r}" == 0 ]] && ! grep -qE 'x86-64-v[34]|CPU does not support|Illegal instruction' <<< "${out}"; then
            echo "  ok    [rc=0] ${cmd}: $(head -n 1 <<< "${out}" | cut -c1-140)"
        else
            echo "  FAIL  [rc=${r}] ${cmd}: $(head -n 3 <<< "${out}")"
            rc=1
        fi
    done

    echo "e. serving the catalog (arbitrary UID, as with the restricted SCC)"
    local name="percona-ubi9-catalog-test-$$" _
    docker run -d --name "${name}" --user 1000650000:0 "${LOCAL_CATALOG}" >/dev/null
    out=""
    for _ in $(seq 1 30); do
        if out="$(docker exec "${name}" /bin/grpc_health_probe -addr=localhost:50051 2>&1)"; then
            break
        fi
        sleep 2
    done
    if grep -q 'SERVING' <<< "${out}"; then
        echo "  ok    grpc_health_probe: ${out}"
    else
        echo "  FAIL  grpc_health_probe: ${out}"
        docker logs "${name}" 2>&1 | tail -n 20 | sed 's/^/        /'
        rc=1
    fi
    docker container rm -f "${name}" >/dev/null

    # Every operator image the catalog deploys (operators.txt, written by
    # olm-fbc.py: at least one per bundle) must itself run on x86-64-v2. The
    # rebuilt ones get the full checks in their own jobs; this covers the
    # bundles copied unchanged as well. With REQUIRE_PUBLISHED_IMAGES=0 (pull
    # requests) an image that is not published yet is skipped: its target job
    # verifies it.
    echo "f. operator images deployed by the catalog"
    local images=() img
    mapfile -t images < <(cut -d' ' -f2 "${OLM_DIR}/operators.txt" | sort -u)
    [[ ${#images[@]} -gt 0 ]] || die "no operator images in ${OLM_DIR}/operators.txt"
    for img in "${images[@]}"; do
        if [[ "${REQUIRE_PUBLISHED_IMAGES:-1}" == 0 && -z "$(remote_digest "${img}")" ]]; then
            echo "  skip  ${img}: not published yet (verified by its target job)"
            continue
        fi
        if "${ROOT_DIR}/scripts/verify-image.sh" --generic "${img}" > "${OLM_DIR}/verify-operator.log" 2>&1; then
            echo "  ok    ${img}: $(grep -m1 -E '^  ok    Red Hat' "${OLM_DIR}/verify-operator.log" | sed 's/^  ok    //')"
        else
            echo "  FAIL  ${img}:"
            grep -E 'FAIL|error' "${OLM_DIR}/verify-operator.log" | sed 's/^/        /'
            rc=1
        fi
    done
    [[ "${rc}" == 0 ]] || die "catalog verification failed"
    log "catalog ${LOCAL_CATALOG} verified"
}

push() {
    [[ -s "${OLM_DIR}/catalog.content" ]] || die "catalog not built (olm-catalog.sh build)"
    local hash digest tag
    hash="$(cat "${OLM_DIR}/catalog.content")"
    if [[ "$(remote_label "${CATALOG_IMAGE}:latest" "${CONTENT_LABEL}")" == "${hash}" ]]; then
        log "${CATALOG_IMAGE}:latest has the same content (${hash:0:12}); not pushed again"
    else
        tag="${CATALOG_IMAGE}:$(date -u +%Y%m%d)-${hash:0:12}"
        for t in "${tag}" "${CATALOG_IMAGE}:latest"; do
            log "push ${t}"
            docker tag "${LOCAL_CATALOG}" "${t}"
            docker push -q "${t}" >/dev/null
        done
    fi
    digest="$(remote_digest "${CATALOG_IMAGE}:latest")"
    [[ "${digest}" == sha256:* ]] || die "cannot read the digest of ${CATALOG_IMAGE}:latest"
    [[ "$(remote_label "${CATALOG_IMAGE}:latest" "${CONTENT_LABEL}")" == "${hash}" ]] \
        || die "${CATALOG_IMAGE}:latest does not carry content ${hash}"
    echo "${CATALOG_IMAGE}:latest ${CATALOG_IMAGE}@${digest}" | tee "${OLM_DIR}/catalog.txt"
}

case "${1:-}" in
    build) build ;;
    verify) verify ;;
    push) push ;;
    *) die "usage: $0 build|verify|push" ;;
esac
