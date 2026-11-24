#!/bin/bash
# Static checks of every target (no image is built):
#  - every upstream/<image>/<version> submodule has a versions/<image>/<version>.env
#    with MODE=build, and every MODE=build target has its submodule;
#  - the submodule is checked out at the commit of UPSTREAM_REF in UPSTREAM_REPO
#    (needs network: git ls-remote);
#  - patches/<target>/*.patch apply, the Dockerfile exists and takes BASE_IMAGE;
#  - MODE=copy targets pin SOURCE_IMAGE by digest (checked by scripts/lib.sh).
# usage: check-targets.sh [TARGET...]   (default: every target)
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
cleanup() { rm -rf -- "${tmp:?}"; }
trap cleanup EXIT

# Submodules without a target.
while read -r _ path; do
    t="${path#upstream/}"
    [[ -f "${ROOT_DIR}/versions/${t}.env" ]] || die "submodule ${path} has no versions/${t}.env"
done < <(git -C "${ROOT_DIR}" config -f .gitmodules --get-regexp '^submodule\..*\.path$')

if [[ $# -eq 0 ]]; then
    mapfile -t targets < <(list_targets)
else
    targets=("$@")
fi

for t in "${targets[@]}"; do
    (
        unload_env
        export TARGET="${t}" BUILD_DIR="${tmp}/build"
        # shellcheck source=scripts/lib.sh
        source "$(dirname "$0")/lib.sh"
        if [[ "${MODE}" == copy ]]; then
            [[ ! -e "${UPSTREAM_DIR}" ]] || die "${TARGET}: MODE=copy but upstream/${TARGET} exists"
            log "${TARGET}: copy of ${SOURCE_IMAGE}"
            exit 0
        fi
        git -C "${ROOT_DIR}" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
            | awk -v p="upstream/${TARGET}" '$2 == p { found=1 } END { exit !found }' \
            || die "${TARGET}: no submodule upstream/${TARGET} in .gitmodules"
        url="$(git -C "${ROOT_DIR}" config -f .gitmodules "submodule.upstream/${TARGET}.url")"
        [[ "${url%.git}" == "${UPSTREAM_REPO%.git}" ]] || die "${TARGET}: submodule url ${url} != UPSTREAM_REPO ${UPSTREAM_REPO}"
        # The recorded gitlink (what a fresh clone checks out) and the checkout
        # must agree: a `git submodule add` followed by a checkout of the tag
        # without `git add` leaves the gitlink at the default branch.
        have="$(git -C "${ROOT_DIR}" ls-files -s "upstream/${TARGET}" | awk '$1 == "160000" { print $2 }')"
        [[ -n "${have}" ]] || die "${TARGET}: upstream/${TARGET} is not recorded as a submodule (git add it)"
        checkout="$(upstream_commit)"
        [[ "${checkout}" == "${have}" ]] \
            || die "${TARGET}: upstream/${TARGET} is checked out at ${checkout} but recorded at ${have} (git add upstream/${TARGET})"
        # Annotated tags: the peeled (^{}) line is the commit; lightweight: the tag line.
        refs="$(git ls-remote "${UPSTREAM_REPO}" "refs/tags/${UPSTREAM_REF}" "refs/tags/${UPSTREAM_REF}^{}")"
        want="$(awk '/\^\{\}$/ { print $1; exit }' <<< "${refs}")"
        [[ -n "${want}" ]] || want="$(awk 'NR == 1 { print $1 }' <<< "${refs}")"
        [[ -n "${want}" ]] || die "${TARGET}: tag ${UPSTREAM_REF} not found in ${UPSTREAM_REPO}"
        [[ "${have}" == "${want}" ]] || die "${TARGET}: upstream/${TARGET} is at ${have}, ${UPSTREAM_REF} is ${want}"
        prepare_src
        f="${SRC_DIR}/${DOCKERFILE}"
        [[ -f "${f}" ]] || die "${TARGET}: no ${DOCKERFILE}"
        grep -qE '^ARG BASE_IMAGE(=|$)' "${f}" || die "${TARGET}: ${DOCKERFILE} has no 'ARG BASE_IMAGE'"
        log "${TARGET}: ${UPSTREAM_REF} = ${have}, patches apply, ${DOCKERFILE} takes BASE_IMAGE"
    )
done
log "all targets OK"
