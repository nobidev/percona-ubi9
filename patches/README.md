# Patches

`patches/<image>/<version>/*.patch` are applied in name order, with
`git apply -p1`, to a copy of `upstream/<image>/<version>` in
`build/src/<image>/<version>` before it is built (`scripts/lib.sh`
`prepare_src`). The submodules themselves are never modified.

The UBI 9 base needs no patch: the upstream Dockerfiles of every
`MODE=build` target take a `BASE_IMAGE` build argument. Add a patch only for a
change that a build argument cannot make. Create it with `git format-patch`
against the upstream tag (paths relative to the upstream repository root), and
run `make check`. A patch changes the target's build key, so CI rebuilds and
republishes the image under the same tags.

Current patches:

| Targets | Patch | Why |
|---|---|---|
| `percona-postgresql-operator/2.9.0`, `3.0.0`, `3.1.0` | `0001-Accept-cert-manager-s-validating-webhook-under-any-n.patch` | cert-manager installed through OLM names its validating webhook `validate.webhooks.cert-manager.io`; the cert-manager check (`cmapichecker`, which expects `webhook.cert-manager.io`) failed, and the PostgresCluster controller stopped reconciling. The patch treats exactly the expected denial of the check's invalid CertificateRequest (`spec.request` is not a PEM block) by a webhook named `cert-manager.io` or a subdomain of it as success; other denials are still errors. Unit tests included. |
