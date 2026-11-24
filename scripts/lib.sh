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
