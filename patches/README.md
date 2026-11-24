# Patches

`patches/<image>/<version>/*.patch` are applied in name order, with
`git apply -p1`, to a copy of `upstream/<image>/<version>` in
`build/src/<image>/<version>` before it is built (`scripts/lib.sh`
`prepare_src`). The submodules themselves are never modified.

No target needs a patch at the moment: the upstream Dockerfiles of every
`MODE=build` target take a `BASE_IMAGE` build argument, which selects UBI 9.
Add a patch only for a change that a build argument cannot make (for
example a Dockerfile without `ARG BASE_IMAGE`). Create it with
`git format-patch` against the upstream tag, and run `make check`.
