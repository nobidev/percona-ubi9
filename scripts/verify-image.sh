#!/bin/bash
# Verify that the image of TARGET runs on an x86-64-v2 CPU (Intel Ivy Bridge,
# no AVX2), on its exported root filesystem:
#   a. /etc/redhat-release matches EXPECT_RELEASE (RHEL 9.x);
#   b. every dynamic binary in BINARIES needs at most GLIBC_${MAX_GLIBC} and
#      finds its interpreter and libraries inside the image; no ELF object in
#      the image is marked for x86-64-v3/v4 (scripts/check-isa.py);
#   c. COMMON_SMOKE_CMDS (must exit 0) and SMOKE_CMDS (may fail for other
#      reasons, e.g. no kubeconfig) run under
#      `qemu-x86_64 -cpu ${QEMU_CPU} -L <rootfs>` without an ISA error
#      ("x86-64-v3", SIGILL), without exit code 127 and without a signal.
#
# With --control, IMAGE is a control image (a UBI 10 upstream image): the same
# execution test must FAIL there with "CPU does not support x86-64-v3",
# otherwise the test cannot tell v2 from v3 and proves nothing (d).
#
# usage: verify-image.sh [--control] IMAGE
source "$(dirname "$0")/lib.sh"
[[ -n "${TARGET:-}" ]] || die "TARGET is not set (make targets)"

control=0
if [[ "${1:-}" == --control ]]; then
    control=1
    shift
fi
[[ $# -eq 1 ]] || die "usage: $0 [--control] IMAGE"
image="$1"

command -v qemu-x86_64 >/dev/null || die "qemu-x86_64 not found (install qemu-user)"
command -v objdump >/dev/null || die "objdump not found (install binutils)"
command -v readelf >/dev/null || die "readelf not found (install binutils)"
if [[ "${control}" == 0 ]]; then
    [[ -n "${BINARIES:-}" ]] || die "${TARGET}: BINARIES is empty"
    [[ -n "${SMOKE_CMDS:-}" ]] || die "${TARGET}: SMOKE_CMDS is empty"
fi

ISA_ERRORS='x86-64-v[34]|CPU does not support|ISA level|Illegal instruction|SIGILL'
V3_ERROR='CPU does not support x86-64-v3'
failures=0
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
ok() { printf '  ok    %s\n' "$*"; }

mkdir -p "${WORK_DIR}"
rootfs="$(mktemp -d "${WORK_DIR}/rootfs.XXXXXX")"
rundir="$(mktemp -d "${WORK_DIR}/run.XXXXXX")"
ctr=""
cleanup() {
    [[ -z "${ctr}" ]] || docker container rm -f "${ctr}" >/dev/null 2>&1 || true
    chmod -R u+rwX -- "${rootfs:?}" "${rundir:?}" 2>/dev/null || true
    rm -rf -- "${rootfs:?}" "${rundir:?}"
}
trap cleanup EXIT

# Resolve a path inside the rootfs the way a chroot would: walk it component
# by component, follow symlinks (absolute targets restart at the rootfs, never
# at the host's /), apply '..' to the already resolved directory. At most 40
# symlinks in total. Prints the host path; returns 1 on a symlink loop.
in_rootfs() {
    local out="" comp target n=0 i=0 todo tcomps
    IFS=/ read -r -a todo <<< "${1#/}"
    while [[ "${i}" -lt ${#todo[@]} ]]; do
        comp="${todo[i]}"
        i=$((i + 1))
        case "${comp}" in
            '' | .) continue ;;
            ..) out="${out%/*}"; continue ;;
        esac
        if [[ -L "${rootfs}${out}/${comp}" ]]; then
            n=$((n + 1))
            [[ "${n}" -le 40 ]] || return 1
            target="$(readlink "${rootfs}${out}/${comp}")"
            [[ "${target}" != /* ]] || out=""
            tcomps=()
            IFS=/ read -r -a tcomps <<< "${target#/}"
            todo=("${tcomps[@]}" "${todo[@]:i}")
            i=0
        else
            out="${out}/${comp}"
        fi
    done
    printf '%s%s\n' "${rootfs}" "${out:-/}"
}

# Host path of a file the emulated program opens: qemu -L tries
# <rootfs>/<path> through the host kernel, so absolute symlinks there point
# into the host. The file only counts as part of the image if its real path
# stays inside the rootfs. Returns 1 otherwise.
image_file() {
    local real
    real="$(realpath -e -- "${rootfs}$1" 2>/dev/null)" || return 1
    [[ "${real}" == "${rootfs}"/* && -f "${real}" ]] || return 1
    printf '%s\n' "${real}"
}

# Host path of a shared library (a name from DT_NEEDED or an absolute
# PT_INTERP path) in the image's default library directories. RUNPATH and
# ld.so.conf.d are not consulted (a library only found there is reported
# missing).
image_lib() {
    local c
    if [[ "$1" == /* ]]; then
        image_file "$1"
        return
    fi
    for c in /lib64 /usr/lib64 /usr/local/lib64; do
        image_file "${c}/$1" && return 0
    done
    return 1
}

# Program interpreter (PT_INTERP) of an ELF file, empty for static ones.
elf_interp() {
    readelf -lW "$1" | sed -n 's/.*Requesting program interpreter: \(.*\)]$/\1/p'
}

# --- export the image root filesystem -----------------------------------------
if ! docker image inspect "${image}" >/dev/null 2>&1; then
    [[ "${image}" != localhost/* ]] || die "${image} is not built (make build TARGET=${TARGET})"
    docker pull -q --platform "${PLATFORM}" "${image}" >/dev/null
fi
ctr="$(docker create --platform "${PLATFORM}" "${image}" /bin/true)"
docker export "${ctr}" | tar -x -C "${rootfs}" --exclude='dev/*' \
    || die "cannot export the root filesystem of ${image}"
docker container rm -f "${ctr}" >/dev/null
ctr=""
# Files that are not readable by their owner would be skipped by the scans.
chmod -R u+rX -- "${rootfs}"
id="$(docker image inspect --format '{{.Id}}' "${image}")"
if [[ "${control}" == 1 ]]; then
    printf '### control image %s (%s)\n' "${image}" "${id}"
else
    printf '### %s: %s (%s)\n' "${TARGET}" "${image}" "${id}"
fi

# --- a. base OS ----------------------------------------------------------------
echo "a. /etc/redhat-release"
release="$(cat "${rootfs}/etc/redhat-release" 2>/dev/null || echo '<missing>')"
if [[ "${control}" == 1 ]]; then
    printf '  info  %s\n' "${release}"
elif grep -qE "${EXPECT_RELEASE}" <<< "${release}"; then
    ok "${release}"
else
    fail "${release} (want ${EXPECT_RELEASE})"
fi

# The execution test relies on the image's own glibc: qemu -L falls back to
# host files for anything missing from the rootfs (or reached through an
# absolute symlink), which would hide a problem.
glibc_ok=0
if bash_exe="$(in_rootfs /usr/bin/bash)" && [[ -f "${bash_exe}" ]] \
    && interp="$(elf_interp "${bash_exe}")" && [[ -n "${interp}" ]] \
    && image_file "${interp}" >/dev/null && image_lib libc.so.6 >/dev/null; then
    glibc_ok=1
fi
if [[ "${glibc_ok}" == 0 ]]; then
    [[ "${control}" == 0 ]] || die "control image ${image}: no /usr/bin/bash with its own interpreter and libc.so.6"
    fail "/usr/bin/bash, its interpreter or libc.so.6 is not in the image: the execution test would use the host's glibc"
fi

# --- b. GLIBC requirement, libraries and ISA marking ---------------------------
if [[ "${control}" == 0 ]]; then
    echo "b. GLIBC symbol versions (max GLIBC_${MAX_GLIBC}) and shared libraries"
    read -r -a binaries <<< "${BINARIES}"
    for bin in "${binaries[@]}"; do
        if ! f="$(in_rootfs "${bin}")" || [[ ! -f "${f}" ]]; then
            fail "${bin}: missing"
            continue
        fi
        if ! headers="$(objdump -p "${f}" 2>&1)"; then
            fail "${bin}: not an ELF file objdump can read: $(head -n 1 <<< "${headers}")"
            continue
        fi
        mapfile -t needed < <(awk '$1 == "NEEDED" { print $2 }' <<< "${headers}")
        interp="$(elf_interp "${f}")"
        if [[ ${#needed[@]} -eq 0 && -z "${interp}" ]]; then
            ok "${bin}: static (no interpreter, no shared library dependencies)"
            continue
        fi
        if ! symbols="$(objdump -T "${f}" 2>&1)"; then
            fail "${bin}: objdump -T failed: $(head -n 1 <<< "${symbols}")"
            continue
        fi
        # Highest GLIBC_x.y over the symbol versions and the version
        # references (also those without symbols).
        versions="$(printf '%s\n%s\n' "${symbols}" "${headers}" \
            | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -uV || true)"
        highest="$(tail -n 1 <<< "${versions}")"
        # Every library (and the interpreter) must be in the image, and every
        # version it is required to define (GLIBC_2.34, GLIBC_ABI_DT_RELR,
        # GCC_3.0, ...) must be defined by the image's copy.
        bad=()
        libs=("${needed[@]}")
        [[ -z "${interp}" ]] || libs+=("${interp}")
        for lib in "${libs[@]}"; do
            image_lib "${lib}" >/dev/null || bad+=("${lib} not in the image")
        done
        while read -r lib ver; do
            [[ -n "${lib}" ]] || continue
            if ! g="$(image_lib "${lib}")"; then
                continue # already reported above
            fi
            if ! objdump -p "${g}" | awk '/^Version definitions:/ { d=1; next } /^Version References:/ { d=0 } d && $1 ~ /^[0-9]+$/ { print $4 } d && NF == 1 { print $1 }' \
                | grep -qxF "${ver}"; then
                bad+=("${ver} not defined by the image's ${lib}")
            fi
        done < <(awk '/^Version References:/ { r=1; next } r && /required from/ { lib=$3; sub(/:$/, "", lib); next } r && NF == 4 && $1 ~ /^0x/ { print lib, $4 } r && NF == 0 { r=0 }' <<< "${headers}")
        deps="${needed[*]}"
        if [[ ${#bad[@]} -gt 0 ]]; then
            fail "${bin}: $(printf '%s; ' "${bad[@]}" | sed 's/; $//')"
        elif [[ -z "${highest}" ]]; then
            ok "${bin}: dynamic, no GLIBC versioned symbols (${deps})"
        elif [[ "$(printf '%s\n%s\n' "${highest}" "${MAX_GLIBC}" | sort -V | tail -n 1)" == "${MAX_GLIBC}" ]]; then
            ok "${bin}: dynamic, highest GLIBC_${highest}, all version references defined in the image (${deps})"
        else
            fail "${bin}: dynamic, needs GLIBC_${highest} > GLIBC_${MAX_GLIBC} (${deps})"
        fi
    done
    echo "b. ISA marking of every ELF object"
    if python3 -I "${ROOT_DIR}/scripts/check-isa.py" "${rootfs}" | sed 's/^/  /'; then
        :
    else
        fail "ELF objects marked for x86-64-v3/v4 (see above)"
    fi
fi

# --- c. execution on an emulated x86-64-v2 CPU ----------------------------------
echo "c. execution under qemu-x86_64 -cpu ${QEMU_CPU} -L <rootfs>"
split_cmds strict_cmds "${COMMON_SMOKE_CMDS}"
split_cmds target_cmds "${SMOKE_CMDS:-}"
control_v3=0
run_cmd() {
    local strict="$1" cmd="$2" argv bin exe rc out first isa
    read -r -a argv <<< "${cmd}"
    [[ ${#argv[@]} -gt 0 ]] || return 0
    bin="${argv[0]}"
    if ! exe="$(in_rootfs "${bin}")" || [[ ! -f "${exe}" || ! -x "${exe}" ]]; then
        if [[ "${control}" == 1 ]]; then
            printf '  skip  %s (not in image)\n' "${cmd}"
        else
            fail "${cmd}: ${bin} missing"
        fi
        return 0
    fi
    rc=0
    # Clean environment, scratch working directory (some binaries write
    # logs relative to it).
    out="$(cd "${rundir}" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/nonexistent \
        timeout -k 5 "${SMOKE_TIMEOUT}" \
        qemu-x86_64 -cpu "${QEMU_CPU}" -L "${rootfs}" -0 "${bin}" "${exe}" "${argv[@]:1}" \
        2>&1 < /dev/null)" || rc=$?
    out="$(grep -v "TCG doesn't support" <<< "${out}" || true)"
    first="$(head -n 1 <<< "${out}" | cut -c1-160)"
    isa=0
    grep -qE "${ISA_ERRORS}" <<< "${out}" && isa=1
    if [[ "${control}" == 1 ]]; then
        if grep -qF "${V3_ERROR}" <<< "${out}"; then
            printf '  fails as expected  [rc=%s] %s: %s\n' "${rc}" "${cmd}" "${first}"
            [[ "${strict}" == 0 ]] || control_v3=1
        else
            printf '  runs  [rc=%s] %s: %s\n' "${rc}" "${cmd}" "${first}"
        fi
        return 0
    fi
    if [[ "${isa}" == 1 || "${rc}" == 127 ]]; then
        fail "[rc=${rc}] ${cmd}: $(grep -E "${ISA_ERRORS}" <<< "${out}" | head -n 1 || echo "${first}")"
    elif [[ "${strict}" == 1 && "${rc}" != 0 ]]; then
        fail "[rc=${rc}] ${cmd}: must exit 0: ${first}"
    elif [[ "${rc}" == 124 || "${rc}" == 137 ]]; then
        # 124: stopped by timeout; 137: killed 5s after that.
        ok "[rc=${rc}, still running after ${SMOKE_TIMEOUT}s] ${cmd}: ${first}"
    elif [[ "${rc}" -ge 128 ]]; then
        fail "[rc=${rc}] ${cmd}: killed by signal $((rc - 128)): ${first}"
    else
        ok "[rc=${rc}] ${cmd}: ${first}"
    fi
}
for cmd in "${strict_cmds[@]}"; do run_cmd 1 "${cmd}"; done
for cmd in "${target_cmds[@]}"; do run_cmd 0 "${cmd}"; done

# --- result ---------------------------------------------------------------------
if [[ "${control}" == 1 ]]; then
    echo "d. control"
    if [[ "${control_v3}" == 1 ]]; then
        ok "control image fails with '${V3_ERROR}': the execution test detects x86-64-v3"
        exit 0
    fi
    fail "control image did not fail with '${V3_ERROR}' on ${COMMON_SMOKE_CMDS}: the execution test proves nothing"
    exit 1
fi
if [[ "${failures}" != 0 ]]; then
    die "${TARGET}: ${failures} check(s) failed for ${image}"
fi
log "${TARGET}: ${image} verified for x86-64-v2 (${QEMU_CPU})"
