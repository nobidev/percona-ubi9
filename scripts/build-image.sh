#!/bin/bash
# Build TARGET (MODE=build) from its pinned upstream sources with the UBI 9
# base, the same way the upstream e2e-tests/build script does (docker buildx,
# GIT_COMMIT/GIT_BRANCH/BUILD_TIME/GO_LDFLAGS build arguments), into the local
# image store as LOCAL_IMAGE. For MODE=copy, pull SOURCE_IMAGE instead.
source "$(dirname "$0")/lib.sh"
[[ -n "${TARGET:-}" ]] || die "TARGET is not set (make targets)"

if [[ "${MODE}" == copy ]]; then
    log "${TARGET}: MODE=copy, pulling ${SOURCE_IMAGE} (${PLATFORM})"
    docker pull --platform "${PLATFORM}" "${SOURCE_IMAGE}"
    exit 0
fi

prepare_src
if [[ -n "${PREPARE_CMD:-}" ]]; then
    log "${TARGET}: ${PREPARE_CMD}"
    (cd "${SRC_DIR}" && bash -euo pipefail -c "${PREPARE_CMD}")
fi

dockerfile="${SRC_DIR}/${DOCKERFILE}"
[[ -f "${dockerfile}" ]] || die "${TARGET}: no ${DOCKERFILE} in upstream/${TARGET}"
# The base is selected with the upstream BASE_IMAGE build argument; a
# Dockerfile without it would silently keep its own base.
grep -qE '^ARG BASE_IMAGE(=|$)' "${dockerfile}" \
    || die "${TARGET}: ${DOCKERFILE} has no 'ARG BASE_IMAGE'; add a patch in patches/${TARGET}/"

commit="$(upstream_commit)"
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "${TARGET}: building ${LOCAL_IMAGE} (${UPSTREAM_REF} ${commit}, BASE_IMAGE=${UBI_BASE_IMAGE}, ${PLATFORM})"
# EXTRA_BUILD_FLAGS: optional extra `docker buildx build` flags
# (e.g. --no-cache --pull).
# shellcheck disable=SC2086
docker buildx build \
    --platform "${PLATFORM}" \
    --build-arg GIT_COMMIT="${commit}" \
    --build-arg GIT_BRANCH="${UPSTREAM_REF}" \
    --build-arg BUILD_TIME="${build_time}" \
    --build-arg GO_LDFLAGS="-w -s -trimpath" \
    --build-arg BASE_IMAGE="${UBI_BASE_IMAGE}" \
    --label org.opencontainers.image.source="${SOURCE_URL}" \
    --label org.opencontainers.image.created="${build_time}" \
    --label org.opencontainers.image.revision="${commit}" \
    --label org.opencontainers.image.version="${VERSION}" \
    --label org.opencontainers.image.base.name="registry.access.redhat.com/${UBI_BASE_IMAGE}/ubi-minimal" \
    --label io.nobidev.percona-ubi9.upstream="${UPSTREAM_REPO}@${UPSTREAM_REF}" \
    --progress plain \
    --load \
    ${EXTRA_BUILD_FLAGS:-} \
    -t "${LOCAL_IMAGE}" \
    -f "${dockerfile}" \
    "${SRC_DIR}"
log "${TARGET}: built ${LOCAL_IMAGE}"
