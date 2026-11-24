#!/bin/bash
# Report whether published images can be pulled anonymously (a GHCR package
# is private when it is first created).
# Informational: exits 0 either way unless STRICT=1.
# usage: check-public.sh [TARGET...]            (default: every target)
#        check-public.sh --images REF [REF...]  (REF: host/path:tag or host/path@sha256:...)
source "$(dirname "$0")/lib.sh"

refs=()
if [[ "${1:-}" == --images ]]; then
    shift
    refs=("$@")
else
    if [[ $# -eq 0 ]]; then
        mapfile -t targets < <(list_targets)
    else
        targets=("$@")
    fi
    for t in "${targets[@]}"; do
        refs+=("${REGISTRY}/${t%%/*}:${t#*/}")
    done
fi

private=0
for ref in "${refs[@]}"; do
    if [[ "${ref}" == *@* ]]; then
        repo="${ref%@*}"
        reference="${ref#*@}"
    else
        repo="${ref%:*}"
        reference="${ref##*:}"
    fi
    host="${repo%%/*}"
    path="${repo#*/}"
    token="$(curl -fsS "https://${host}/token?scope=repository:${path}:pull" 2>/dev/null \
        | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))' 2>/dev/null || true)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${host}/v2/${path}/manifests/${reference}" || true)"
    if [[ "${code}" == 200 ]]; then
        echo "public   ${ref}"
    else
        echo "private  ${ref} (anonymous pull: HTTP ${code}; not published yet, or the package is private: set it to Public in its GitHub package settings)"
        private=1
    fi
done
[[ "${STRICT:-0}" != 1 || "${private}" == 0 ]]
