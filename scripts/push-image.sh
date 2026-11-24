#!/bin/bash
# Publish TARGET under PUBLISH_TAGS (${REGISTRY}/<image>:<version> and
# :<version>-${TAG_SUFFIX}) and record the digests in
# ${WORK_DIR}/digests.txt. Run only after scripts/verify-image.sh passed.
#   MODE=build: push LOCAL_IMAGE (linux/amd64).
#   MODE=copy:  copy SOURCE_IMAGE unchanged (every platform, same digest).
# Needs `docker login` to the registry.
source "$(dirname "$0")/lib.sh"
[[ -n "${TARGET:-}" ]] || die "TARGET is not set (make targets)"
command -v jq >/dev/null || die "jq not found"

remote_digest() {
    docker buildx imagetools inspect --format '{{json .Manifest}}' "$1" | jq -r .digest
}

mkdir -p "${WORK_DIR}"
digests="${WORK_DIR}/digests.txt"
: > "${digests}.tmp"

if [[ "${MODE}" == build ]]; then
    docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1 || die "${LOCAL_IMAGE} is not built (make build TARGET=${TARGET})"
    for tag in "${PUBLISH_TAGS[@]}"; do
        log "push ${tag}"
        docker tag "${LOCAL_IMAGE}" "${tag}"
        docker push -q "${tag}" >/dev/null
    done
    want=""
else
    want="${SOURCE_IMAGE##*@}"
    args=()
    for tag in "${PUBLISH_TAGS[@]}"; do args+=(--tag "${tag}"); done
    log "copy ${SOURCE_IMAGE} -> ${PUBLISH_TAGS[*]}"
    docker buildx imagetools create "${args[@]}" "${SOURCE_IMAGE}"
fi

first=""
for tag in "${PUBLISH_TAGS[@]}"; do
    digest="$(remote_digest "${tag}")"
    [[ "${digest}" == sha256:* ]] || die "cannot read the digest of ${tag}"
    [[ -z "${want}" || "${digest}" == "${want}" ]] || die "${tag} has digest ${digest}, want ${want} (copy of ${SOURCE_IMAGE})"
    [[ -z "${first}" || "${digest}" == "${first}" ]] || die "${tag} has digest ${digest}, but ${PUBLISH_TAGS[0]} has ${first}"
    if [[ "${MODE}" == build ]]; then
        # The pushed manifest must be the verified local image.
        docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${LOCAL_IMAGE}" \
            | grep -qxF "${IMAGE_REPO}@${digest}" \
            || die "${tag} (${digest}) is not the verified ${LOCAL_IMAGE}"
    fi
    first="${digest}"
    echo "${tag} ${digest}" | tee -a "${digests}.tmp"
done
mv "${digests}.tmp" "${digests}"
