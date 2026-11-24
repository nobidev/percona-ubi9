# OLM catalog

`ghcr.io/nobidev/percona-ubi9/catalog:latest` is a file-based OLM catalog
with the Percona operators, so that clusters install and upgrade them through
OLM (Subscriptions, InstallPlans) instead of editing operator Deployments,
which OLM would revert.

## Contents

| Package | Bundles (channel `stable`) | Operator image |
|---|---|---|
| `percona-postgresql-operator` | `v2.8.2` → `v2.9.0` → `v3.0.0` → `v3.1.0` | `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:<version>` |
| `percona-server-mongodb-operator` | `v1.23.1` | `ghcr.io/nobidev/percona-ubi9/percona-server-mongodb-operator:1.23.1` |
| `percona-server-mysql-operator` | `v1.3.0` | `docker.io/percona/percona-server-mysql-operator:1.3.0` (upstream, UBI 9) |
| `percona-xtradb-cluster-operator` | `v1.20.0` | `docker.io/percona/percona-xtradb-cluster-operator:1.20.0` (upstream, UBI 9) |

Every bundle comes from the community operator catalog
(`registry.access.redhat.com/redhat/community-operator-index:v4.20`, pinned by
digest in `versions/common.env`); the bundles are pinned by digest in
`bundles/<package>/<version>.env`:

* `MODE=rewrite`: the upstream bundle with every occurrence of the upstream
  operator image (`IMAGE_FROM`) replaced by the image published here. CI
  checks that undoing the replacement gives the upstream bundle byte for byte,
  and that `opm render` of both bundles is identical apart from that image.
  The image is referenced by **tag**: the operators derive their init image
  from their own image reference (`<repository>:<crVersion>`).
* `MODE=copy`: the upstream bundle copied unchanged (same digest) to
  `ghcr.io/nobidev/percona-ubi9/<package>-bundle`.

Packages (description, icon, default channel) and channels come from the
upstream catalog, restricted to the bundles shipped here. Where an entry
`replaces` a bundle that is not shipped, it replaces the nearest shipped
bundle along the upstream chain instead. `skipRange` values like `<v2.8.2`
(not valid semver, rejected by `opm validate`) become `<2.8.2`.

A bundle's `SKIP_RANGE` replaces the upstream `skipRange` of its channel
entry. Percona supports upgrading the PostgreSQL operator only to the nearest
version, while upstream `v3.0.0` skips `<3.0.0` and `v3.1.0` skips `<3.1.0`
(OLM would offer `v2.8.2` → `v3.1.0` directly). Here `v3.0.0` skips
`>=2.9.0 <3.0.0` and `v3.1.0` skips `>=3.0.0 <3.1.0`, so the only path from
`v2.8.2` is `v2.8.2` → `v2.9.0` → `v3.0.0` → `v3.1.0`, one InstallPlan per
step (`v2.9.0` likewise skips only `>=2.8.2 <2.9.0`). The upgrade to `v3.0.0`
migrates the upstream CRDs from `postgres-operator.crunchydata.com` to
`upstream.pgv2.percona.com` automatically and cannot be undone. The CSVs
inside the bundles keep their upstream `olm.skipRange` annotations (the
bundles are unchanged apart from the image); OLM uses the catalog's channel
entries, so only tools that rebuild channels from the CSV annotations would
see the upstream ranges.

The catalog image is built on `quay.io/operator-framework/opm` (static
binaries). CI checks that it runs on an emulated Ivy Bridge CPU
(`opm version`, `opm validate /configs`), that it serves the catalog over gRPC
as an arbitrary non-root user (as with the `restricted` SCC), and that every
operator image the catalog deploys is RHEL 9 with no x86-64-v3 objects and
runs `bash -c true` on the emulated CPU.

## Images and visibility

| Image | Tags |
|---|---|
| `ghcr.io/nobidev/percona-ubi9/catalog` | `latest` (polled by the CatalogSource), `<date>-<content hash>` |
| `ghcr.io/nobidev/percona-ubi9/<package>-bundle` | `v<version>` |

Bundles and the catalog are pushed only when their content changed, so the
digests stay stable across CI runs. New GHCR packages are private: set the
catalog and the four `*-bundle` packages to **Public** (OLM pulls bundle
images without credentials, like the catalog image).

## Switching a cluster to the catalog

Run these with `oc` against the cluster, one step at a time; each changes the
cluster.

1. **Do not approve** InstallPlans that come from `community-operators` for
   `percona-postgresql-operator` `>= 2.9.0` or `percona-server-mongodb-operator`
   `>= 1.22.0`: they deploy the UBI 10 operator image, which exits with
   `Fatal glibc error: CPU does not support x86-64-v3` on x86-64-v2 nodes.

2. Make sure every Percona Subscription uses manual approval **before**
   changing its source. With `Automatic`, OLM would run
   `percona-postgresql-operator` 2.9.0 → 3.0.0 → 3.1.0 back to back, waiting
   only for each CSV to succeed, not for the CRD migration of 3.0.0:
   ```bash
   oc -n openshift-operators get subscription \
     -o custom-columns=NAME:.metadata.name,SOURCE:.spec.source,APPROVAL:.spec.installPlanApproval,INSTALLED:.status.installedCSV
   oc -n openshift-operators patch subscription <name> --type merge -p '{"spec":{"installPlanApproval":"Manual"}}'
   ```

3. Add the catalog and wait until it is ready:
   ```bash
   oc apply -f deploy/catalogsource.yaml
   oc -n openshift-marketplace get catalogsource percona-ubi9 \
     -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'   # READY
   oc get packagemanifests -l catalog=percona-ubi9
   ```

4. Point the Percona Subscriptions at it (channel and config unchanged). For
   MySQL and PXC the installed CSV is the same bundle, so nothing is
   reinstalled. Include `percona-server-mongodb-operator` if it is installed
   through OLM (it is not on every cluster):
   ```bash
   for s in percona-postgresql-operator percona-server-mysql-operator percona-xtradb-cluster-operator; do
     oc -n openshift-operators patch subscription "$s" --type merge -p '{"spec":{"source":"percona-ubi9"}}'
   done
   ```

5. An InstallPlan computed earlier from `community-operators` is not updated
   by the switch. In a namespace with several Subscriptions (such as
   `openshift-operators`) one InstallPlan can belong to several of them, so
   check what it would install before deleting it: delete it only if
   `clusterServiceVersionNames` lists nothing but the Percona CSVs you are
   switching. OLM then computes a new one:
   ```bash
   oc -n openshift-operators get installplan \
     -o custom-columns=NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames,APPROVED:.spec.approved,CATALOG:.status.bundleLookups[*].catalogSourceRef.name
   oc -n openshift-operators delete installplan <the community one>
   ```

6. Check the new InstallPlan before approving it: its bundle must come from
   `percona-ubi9`, from `ghcr.io/nobidev/percona-ubi9/`:
   ```bash
   oc -n openshift-operators get installplan <name> \
     -o jsonpath='{range .status.bundleLookups[*]}{.catalogSourceRef.name} {.identifier} {.path}{"\n"}{end}'
   ```
   `percona-postgresql-operator` goes one version per InstallPlan
   (2.8.2 → 2.9.0 → 3.0.0 → 3.1.0); approve the next one only when the
   previous step is done. 2.9.0 → 3.0.0 migrates the upstream CRDs from
   `postgres-operator.crunchydata.com` to `upstream.pgv2.percona.com`
   (irreversible; the `APIGroupMigration` condition of each PerconaPGCluster
   shows its progress): follow Percona's upgrade documentation and take
   backups first. Then:
   ```bash
   oc -n openshift-operators patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
   ```

7. Verify: the operator pod runs
   `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:3.1.0`, and the
   init containers of database pods of clusters at an older `crVersion`
   (2.8.2, 2.9.0, 3.0.0) use
   `ghcr.io/nobidev/percona-ubi9/percona-postgresql-operator:<crVersion>`.

To go back, point the Subscriptions at `community-operators` again; OLM does
not downgrade an installed CSV.

## Tags, not digests

The bundles reference operator images by tag (the operators derive their init
image from it), so what a pod runs follows the tag: `docker.io/percona/...`
tags for the copied MySQL/PXC bundles (Percona could re-push them), and this
repository's tags, which move only when a target's sources change or on a
`force_push` run. The catalog verification checks the operator images as the
registry serves them at that time; re-run the workflow to check them again.

## Building locally

```bash
export OLM_REGISTRY=localhost:5000/percona-ubi9 OPM_RUN_ARGS="--network host" REQUIRE_PUBLISHED_IMAGES=0
docker run -d -p 5000:5000 registry:2
make olm-bundles olm-push-bundles olm-catalog olm-verify
```

`OPM_RUN_ARGS` passes extra `docker run` flags to opm (here: reach the local
registry); `REQUIRE_PUBLISHED_IMAGES=0` skips the check that every rewritten
bundle's operator image is already published.

## Adding a bundle

1. Find the bundle in the upstream catalog
   (`/configs/<package>/catalog.json` of `UPSTREAM_INDEX`: `.image` of the
   `olm.bundle`).
2. Add `bundles/<package>/<version>.env`: `MODE=rewrite` with `IMAGE_TARGET`
   (a target in `versions/`) and `IMAGE_FROM` for an operator image rebuilt
   or copied here, `MODE=copy` for an upstream image that already runs on
   x86-64-v2 (check it with `scripts/verify-image.sh --generic <image>`).
3. `make check`, then build locally as above.
