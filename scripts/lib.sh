# shellcheck shell=bash
# Variables defined here are consumed by the scripts that source this file.
# shellcheck disable=SC2034
# Common helpers sourced by every script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Load a KEY=VALUE file without letting it override values exported by the
# caller (so `REGISTRY=... make build` works). Values are taken verbatim.
LOADED_KEYS=()
load_env() {
    local key value
    # `|| [[ -n ... ]]` keeps a last line that has no trailing newline.
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        if [[ -z "${!key:-}" ]]; then
            printf -v "${key}" '%s' "${value}"
            export "${key?}"
            LOADED_KEYS+=("${key}")
        fi
    done < "$1"
}

# Forget the values load_env set, so that lib.sh can be sourced again (in a
# subshell) for another TARGET.
unload_env() {
    [[ ${#LOADED_KEYS[@]} -eq 0 ]] || unset "${LOADED_KEYS[@]}"
    LOADED_KEYS=()
}

# All targets (<image>/<version>), one per versions/<image>/<version>.env.
list_targets() {
    local f
    for f in "${ROOT_DIR}"/versions/*/*.env; do
        f="${f#"${ROOT_DIR}/versions/"}"
        echo "${f%.env}"
    done | sort -V
}

# Target-specific settings are only loaded when TARGET is set; per-target
# files are read first so that they win over versions/common.env.
if [[ -n "${TARGET:-}" ]]; then
    [[ "${TARGET}" =~ ^[a-z0-9-]+/[0-9A-Za-z.+-]+$ ]] || die "invalid TARGET=${TARGET} (want <image>/<version>)"
    [[ -f "${ROOT_DIR}/versions/${TARGET}.env" ]] \
        || die "unknown TARGET=${TARGET} (no versions/${TARGET}.env; known: $(list_targets | tr '\n' ' '))"
    load_env "${ROOT_DIR}/versions/${TARGET}.env"
    IMAGE_NAME="${TARGET%%/*}"
    VERSION="${TARGET#*/}"
fi
load_env "${ROOT_DIR}/versions/common.env"

if [[ -n "${TARGET:-}" ]]; then
    case "${MODE:-}" in
        build) [[ -n "${UPSTREAM_REF:-}" && -n "${DOCKERFILE:-}" ]] || die "${TARGET}: MODE=build needs UPSTREAM_REF and DOCKERFILE" ;;
        copy) [[ "${SOURCE_IMAGE:-}" == *@sha256:* ]] || die "${TARGET}: MODE=copy needs SOURCE_IMAGE pinned by digest" ;;
        *) die "${TARGET}: MODE must be build or copy, got '${MODE:-}'" ;;
    esac
    # Pristine upstream sources and the patches applied to a copy of them.
    UPSTREAM_DIR="${ROOT_DIR}/upstream/${TARGET}"
    PATCH_DIR="${ROOT_DIR}/patches/${TARGET}"
    SRC_DIR="${BUILD_DIR}/src/${TARGET}"
    WORK_DIR="${BUILD_DIR}/work/${TARGET}"
    # Published references.
    IMAGE_REPO="${REGISTRY}/${IMAGE_NAME}"
    PUBLISH_TAGS=("${IMAGE_REPO}:${VERSION}" "${IMAGE_REPO}:${VERSION}-${TAG_SUFFIX}")
    # Image built (MODE=build) or pulled (MODE=copy) and verified locally.
    if [[ "${MODE}" == build ]]; then
        LOCAL_IMAGE="${LOCAL_IMAGE:-localhost/percona-ubi9/${IMAGE_NAME}:${VERSION}-${TAG_SUFFIX}}"
    else
        LOCAL_IMAGE="${SOURCE_IMAGE}"
    fi
fi

# --- OLM ------------------------------------------------------------------------
OLM_REGISTRY="${OLM_REGISTRY:-${REGISTRY}}"
OLM_DIR="${BUILD_DIR}/olm"
CONTENT_LABEL=io.nobidev.percona-ubi9.content

# All bundles (<package>/<version>), one per bundles/<package>/<version>.env.
list_bundles() {
    local f
    for f in "${ROOT_DIR}"/bundles/*/*.env; do
        f="${f#"${ROOT_DIR}/bundles/"}"
        echo "${f%.env}"
    done | sort -V
}

# Load bundles/<package>/<version>.env into the current shell (call it in a
# subshell per bundle) and derive the bundle's names:
#   PACKAGE, BUNDLE_VERSION, CSV_NAME, BUNDLE_IMAGE (${OLM_REGISTRY}/<package>-bundle:v<version>)
#   MODE=rewrite: IMAGE_TO (${REGISTRY}/<image>:<version> of IMAGE_TARGET)
load_bundle() {
    local b="$1"
    [[ "${b}" =~ ^[a-z0-9-]+/[0-9A-Za-z.+-]+$ ]] || die "invalid bundle ${b} (want <package>/<version>)"
    [[ -f "${ROOT_DIR}/bundles/${b}.env" ]] || die "unknown bundle ${b} (no bundles/${b}.env)"
    unset MODE UPSTREAM_BUNDLE IMAGE_TARGET IMAGE_FROM SKIP_RANGE
    load_env "${ROOT_DIR}/bundles/${b}.env"
    PACKAGE="${b%%/*}"
    BUNDLE_VERSION="${b#*/}"
    CSV_NAME="${PACKAGE}.v${BUNDLE_VERSION}"
    BUNDLE_IMAGE="${OLM_REGISTRY}/${PACKAGE}-bundle:v${BUNDLE_VERSION}"
    BUNDLE_WORK="${OLM_DIR}/bundles/${b}"
    [[ "${UPSTREAM_BUNDLE:-}" == *@sha256:* ]] || die "${b}: UPSTREAM_BUNDLE must be pinned by digest"
    case "${MODE:-}" in
        copy) IMAGE_TO="" ;;
        rewrite)
            [[ -n "${IMAGE_TARGET:-}" && -n "${IMAGE_FROM:-}" ]] || die "${b}: MODE=rewrite needs IMAGE_TARGET and IMAGE_FROM"
            [[ -f "${ROOT_DIR}/versions/${IMAGE_TARGET}.env" ]] || die "${b}: IMAGE_TARGET ${IMAGE_TARGET} is not a target"
            IMAGE_TO="${REGISTRY}/${IMAGE_TARGET%%/*}:${IMAGE_TARGET#*/}"
            ;;
        *) die "${b}: MODE must be rewrite or copy, got '${MODE:-}'" ;;
    esac
}

# Run opm from OPM_IMAGE with the current directory mounted at /work.
# OPM_RUN_ARGS: extra `docker run` flags (e.g. --network host to reach a
# local registry). Docker credentials are not passed: everything opm reads is
# public or on a local registry.
opm_run() {
    # The opm image has no containers policy.json; image references are
    # pinned by digest, so signatures are not checked.
    local policy="${OLM_DIR}/policy.json"
    mkdir -p "${OLM_DIR}"
    [[ -f "${policy}" ]] || echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "${policy}"
    # shellcheck disable=SC2086
    docker run --rm --user "$(id -u):$(id -g)" -v "${PWD}:/work" -w /work \
        -v "${policy}:/etc/containers/policy.json:ro" -e HOME=/tmp \
        ${OPM_RUN_ARGS:-} "${OPM_IMAGE}" "$@"
}

# Value of a config label of a remote image, empty if the image or the label
# does not exist.
remote_label() {
    docker buildx imagetools inspect --format '{{json .Image}}' "$1" 2>/dev/null \
        | jq -r --arg l "$2" '(if .config then . else (to_entries | map(select(.key | startswith("linux/"))) | .[0].value) end) | .config.Labels[$l] // empty' 2>/dev/null || true
}

# Digest of a remote image (manifest or index), empty if it does not exist.
remote_digest() {
    docker buildx imagetools inspect --format '{{json .Manifest}}' "$1" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null || true
}

# Key of everything a MODE=build image is built from in this repository: the
# target settings, the upstream commit, the patches, the build script and the
# shared build settings. Base images (UBI, golang) are not part of it, so an
# unchanged key means "same sources", not "bit-identical image".
BUILD_KEY_LABEL=io.nobidev.percona-ubi9.build-key
build_key() {
    {
        cat "${ROOT_DIR}/versions/${TARGET}.env"
        git -C "${UPSTREAM_DIR}" rev-parse HEAD
        if [[ -d "${PATCH_DIR}" ]]; then
            find "${PATCH_DIR}" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort | xargs cat
        fi
        cat "${ROOT_DIR}/scripts/build-image.sh"
        declare -f prepare_src
        printf '%s\n' "${UBI_BASE_IMAGE}" "${PLATFORM}" "${SOURCE_URL}"
    } | sha256sum | cut -d' ' -f1
}

# Split a ';'-separated command list into the array named by $1.
split_cmds() {
    local -n _out="$1"
    local IFS=';'
    read -r -a _out <<< "$2"
}

# Upstream commit of a build target's submodule.
upstream_commit() {
    git -C "${UPSTREAM_DIR}" rev-parse HEAD
}

# Copy the submodule of TARGET to SRC_DIR and apply patches/<TARGET>/*.patch.
# Submodules stay pristine; all modifications happen in the copy.
prepare_src() {
    [[ -e "${UPSTREAM_DIR}/.git" ]] \
        || die "submodule upstream/${TARGET} is not initialised (run: git submodule update --init upstream/${TARGET})"
    log "preparing ${SRC_DIR}"
    rm -rf -- "${SRC_DIR:?}"
    mkdir -p "$(dirname "${SRC_DIR}")"
    cp -a "${UPSTREAM_DIR}" "${SRC_DIR}"
    find "${SRC_DIR}" -name .git -prune -exec rm -rf {} +
    # build/ lives inside this repository's work tree, where `git apply` would
    # resolve paths against the top-level repo; use a throwaway repo instead.
    git -C "${SRC_DIR}" init -q
    local p
    shopt -s nullglob
    for p in "${PATCH_DIR}"/*.patch; do
        log "  applying $(basename "${p}")"
        git -C "${SRC_DIR}" apply -p1 --whitespace=nowarn "${p}" \
            || die "patch $(basename "${p}") does not apply to upstream/${TARGET}"
    done
    shopt -u nullglob
    rm -rf -- "${SRC_DIR:?}/.git"
}
