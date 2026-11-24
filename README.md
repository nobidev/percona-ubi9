# percona-ubi9

Rebuilds of [Percona](https://www.percona.com) Kubernetes operator images on
**UBI 9** so that they run on **x86-64-v2** CPUs (Intel Sandy Bridge / Ivy
Bridge Xeons such as the E5-2650 v2 and E5-2670 v2, other pre-Haswell parts,
VMs with a conservative CPU model, ...).

Since Percona Operator for PostgreSQL 2.9.0 and Percona Operator for MongoDB
1.22.0 the operator images are built on UBI 10 (RHEL 10). RHEL 10 is compiled
for **x86-64-v3** (AVX2, BMI, FMA, ...), and its glibc refuses to start on
anything older:

```
Fatal glibc error: CPU does not support x86-64-v3
```

The operator pod exits with code 127, and so does every init container that
runs from the operator image. The upstream Dockerfiles already take a
`BASE_IMAGE` build argument (default `ubi10`); this repository builds the
pinned upstream sources with `BASE_IMAGE=ubi9`, verifies the result on an
emulated Ivy Bridge CPU, and publishes it to `ghcr.io/nobidev/percona-ubi9`.

The repository contains only **submodules, patches and build files**: every
source file comes from the upstream repositories.

## Published images

| Target | Upstream image (base) | Published as | How |
|---|---|---|---|
| `percona-postgresql-operator/3.1.0` | `percona/percona-postgresql-operator:3.1.0` (UBI 10.2) | `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:3.1.0`, `:3.1.0-ubi9` | rebuilt from `v3.1.0` with `BASE_IMAGE=ubi9` |
| `percona-postgresql-operator/3.0.0` | `percona/percona-postgresql-operator:3.0.0` (UBI 10.2) | `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:3.0.0`, `:3.0.0-ubi9` | rebuilt from `v3.0.0` with `BASE_IMAGE=ubi9` |
| `percona-postgresql-operator/2.9.0` | `percona/percona-postgresql-operator:2.9.0` (UBI 10.1) | `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:2.9.0`, `:2.9.0-ubi9` | rebuilt from `v2.9.0` with `BASE_IMAGE=ubi9` |
| `percona-postgresql-operator/2.8.2` | `percona/percona-postgresql-operator:2.8.2` (UBI 9.7) | `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:2.8.2`, `:2.8.2-ubi9` | copied unchanged (same digest, all platforms) |
| `percona-server-mongodb-operator/1.23.1` | `percona/percona-server-mongodb-operator:1.23.1` (UBI 10.2) | `ghcr.io/nobidev/percona-ubi9/percona-server-mongodb-operator:1.23.1`, `:1.23.1-ubi9` | rebuilt from `v1.23.1` with `BASE_IMAGE=ubi9` |

Rebuilt images are `linux/amd64` only; copied images keep every upstream
platform.

### What does not need a rebuild

Image labels and `/etc/redhat-release` of the defaults of the latest
releases (November 2026) show that everything else is already UBI 9 / RHEL 9:

* PostgreSQL 3.1.0: `percona-distribution-postgresql`, `percona-pgbackrest`,
  `percona-pgbouncer`, `fluentbit`, `pmm-client`;
* Percona Server for MySQL operator 1.3.0 (operator, `percona-server`,
  `percona-xtrabackup`, `percona-mysql-router`, `percona-orchestrator`,
  `haproxy`, `percona-toolkit`, binlog server);
* Percona XtraDB Cluster operator 1.20.0 (operator, `percona-xtradb-cluster`,
  `percona-xtrabackup`, `haproxy`, `proxysql2`);
* MongoDB 1.23.1: `percona-server-mongodb`, `percona-backup-mongodb`,
  `percona-search-mongodb`.

Check again whenever a new upstream release is adopted (see
[Adding a target](#adding-a-target)).

### Init containers and `crVersion`

Both operators run the init container of a database cluster from the
operator image, and when the cluster's `crVersion` differs from the
operator's version they use `<operator image repository>:<crVersion>`
(`percona/k8s/util.go` `InitImage` in the PostgreSQL operator,
`pkg/psmdb/init` in the MongoDB operator). Therefore:

* the repository must hold a tag for every `crVersion` still in use
  (`2.8.2`, `2.9.0`, `3.0.0` for clusters not yet moved to `crVersion: 3.1.0`). An upstream
  image that is already UBI 9 is published as a `MODE=copy` target;
* deploy the operator by **tag** (`...:3.1.0`), not by digest: the
  repository is derived by cutting the image reference at the first `:`.

### GHCR visibility

A GHCR package is **private** when it is first created. Clusters that pull
without credentials (OKD without a pull secret for `ghcr.io`) need each
package set to **Public** once, in the package settings
(`https://github.com/orgs/nobidev/packages/container/percona-ubi9%2F<image>/settings`).
`make check-public` (also run by CI after publishing) reports the current
state.

## OLM catalog

`ghcr.io/nobidev/percona-ubi9/catalog:latest` is an OLM catalog
(`deploy/catalogsource.yaml`) whose bundles are the community catalog's
bundles of `percona-postgresql-operator` (2.8.2, 2.9.0, 3.0.0, 3.1.0, upgraded one
version at a time) and
`percona-server-mongodb-operator` (1.23.1) with the operator image replaced
by the images above (nothing else changed, checked by CI), plus unchanged
copies of `percona-server-mysql-operator` 1.3.0 and
`percona-xtradb-cluster-operator` 1.20.0 (already UBI 9). Installing and
upgrading through it is the OLM way: an operator Deployment edited by hand is
reverted by OLM. Details and the switch-over procedure: [docs/olm.md](docs/olm.md).

## Layout

```
upstream/<image>/<version>/   pinned submodules at the upstream tag (never modified in place)
patches/<image>/<version>/    optional git patches applied to a copy in build/src/
versions/common.env           settings shared by all targets
versions/<image>/<version>.env  one file per target (MODE=build or MODE=copy)
bundles/<package>/<version>.env OLM bundles of the catalog (MODE=rewrite or MODE=copy)
scripts/                      build, verification and publishing tooling
deploy/catalogsource.yaml     CatalogSource of the OLM catalog
docs/olm.md                   OLM catalog: contents, checks, switching a cluster to it
.github/workflows/build.yml   CI: check, build + verify every target, OLM catalog, publish
```

## Building

Requirements: Linux x86_64, Docker with buildx, `make`, `git`, `python3`,
`jq`, `objdump` (binutils), `qemu-x86_64` (qemu-user, any version that knows
the `IvyBridge` CPU model), `shellcheck` for `make lint`.

```bash
git clone --recurse-submodules https://github.com/nobidev/percona-ubi9
cd percona-ubi9
make help
make targets
make info TARGET=percona-postgresql-operator/3.1.0

export TARGET=percona-postgresql-operator/3.1.0
make build          # docker buildx build ... --build-arg BASE_IMAGE=ubi9 (MODE=copy: docker pull)
make verify         # checks a-d below
docker login ghcr.io
make push           # MODE=build: push; MODE=copy: carbon copy by digest
```

`make build` runs what the upstream `make build` / `e2e-tests/build` do:
`PREPARE_CMD` (e.g. `make get-pgmonitor`), then `docker buildx build` with
`GIT_COMMIT` (submodule commit), `GIT_BRANCH` (upstream tag), `BUILD_TIME`,
`GO_LDFLAGS="-w -s -trimpath"` and `BASE_IMAGE=ubi9`, plus the labels
`org.opencontainers.image.source=https://github.com/nobidev/percona-ubi9`,
`org.opencontainers.image.revision` and `org.opencontainers.image.version`.

### Verification

`make verify` exports the image root filesystem (`docker create` +
`docker export`) and fails unless:

* **a.** `/etc/redhat-release` is `Red Hat Enterprise Linux release 9.x`;
* **b.** every dynamic binary in `BINARIES` needs at most `GLIBC_2.34`
  (`objdump -T` symbol versions and `objdump -p` version references; static
  binaries are reported as such) and finds its interpreter and libraries in
  the image, and no ELF object in the image is marked for x86-64-v3/v4
  (`scripts/check-isa.py`: GNU ISA property note, `GOAMD64=v3/v4` Go build
  setting);
* **c.** `/usr/bin/bash -c true` (must exit 0) and the target's `SMOKE_CMDS`
  run under `qemu-x86_64 -cpu IvyBridge -L <rootfs> <rootfs>/<binary>`
  without an ISA error (`x86-64-v3`, SIGILL), without exit code 127 and
  without being killed by a signal. Errors such as the missing kubeconfig of
  an operator outside a cluster are expected. The image must ship its own
  `ld-linux-x86-64.so.2` and `libc.so.6`: `qemu -L` falls back to the host's
  files for anything missing from the rootfs, which would hide a problem;
* **d.** (control) the same execution test **fails** with
  `CPU does not support x86-64-v3` on `CONTROL_IMAGE` (the UBI 10 upstream
  image). If it does not, the test cannot tell v2 from v3 and the job fails.

Logs: `build/work/<target>/verify.log` and `control.log`.

## CI

`.github/workflows/build.yml`:

* pull requests: `make check` (shellcheck, python syntax, every submodule at
  the commit of its upstream tag, patches apply, the Dockerfile takes
  `BASE_IMAGE`), then build + verify every target; nothing is pushed;
* pushes to `main` (except Markdown-only changes): the same, then publish
  every target;
* `workflow_dispatch`: choose targets (`all` or a space-separated list) and
  whether to publish (default: yes). Only runs on `main` publish;
* after the target jobs, the `olm` job builds the bundles and the catalog,
  renders and validates them with opm and verifies the catalog image and
  every operator image it deploys (pull requests: on a throwaway local
  registry), then publishes them.

Publishing happens only in `nobidev/percona-ubi9` itself (not in forks), and
publishing runs are never cancelled half-way. Each target is a matrix job; it
publishes only after its own checks a-d passed, and `make push` checks that
the pushed digest is the verified image (`MODE=build`) or the pinned source
digest (`MODE=copy`). The job summary shows the verification logs and the published
digests. A rebuilt image is pushed only when its build key changes (target
settings, upstream commit, patches, build script: label
`io.nobidev.percona-ubi9.build-key`), so the tags keep their digests across
unrelated changes; a `workflow_dispatch` with `force_push` republishes them
(e.g. to pick up current UBI 9 packages). `org.opencontainers.image.revision`
names the upstream commit.

## Adding a target

1. Check the upstream image: if `/etc/redhat-release` is already RHEL 9 and
   the image runs under `make verify`, add a `MODE=copy` target pinned by
   digest (see `versions/percona-postgresql-operator/2.8.2.env`).
2. Otherwise add the submodule at the upstream tag:
   ```bash
   git submodule add https://github.com/percona/<image> upstream/<image>/<version>
   git -C upstream/<image>/<version> fetch --depth 1 origin refs/tags/v<version>
   git -C upstream/<image>/<version> checkout FETCH_HEAD
   git config -f .gitmodules submodule.upstream/<image>/<version>.shallow true
   git add .gitmodules upstream/<image>/<version>   # records the tag commit
   ```
   and `versions/<image>/<version>.env` (copy an existing `MODE=build` file;
   `DOCKERFILE`, `PREPARE_CMD`, `BINARIES`, `SMOKE_CMDS` from the upstream
   Dockerfile and Makefile).
3. If the Dockerfile has no `ARG BASE_IMAGE` (or needs other changes for
   UBI 9), add `patches/<image>/<version>/0001-*.patch` (`git format-patch`
   against the upstream tag).
4. `make check`, then `make build verify TARGET=<image>/<version>`.
5. Also check the operator's other default images (`deploy/cr.yaml`) for
   UBI 10.
