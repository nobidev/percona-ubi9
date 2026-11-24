# percona-ubi9: rebuild Percona operator images on UBI 9 for x86-64-v2 CPUs.
#
# Settings live in versions/common.env and versions/<image>/<version>.env;
# TARGET=<image>/<version> selects one (`make targets` lists them). Anything
# can be overridden on the command line or in the environment, e.g.
#   make build verify TARGET=percona-postgresql-operator/3.1.0
#   make push TARGET=percona-postgresql-operator/3.1.0 REGISTRY=quay.io/me

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Must be set before the export below: GNU make defines an exported, unset
# variable as empty, after which `?=` would no longer apply.
BUILD_DIR ?= $(CURDIR)/build
WORK = $(BUILD_DIR)/work/$(TARGET)

# Settings that the scripts honour when set in the environment.
export TARGET REGISTRY TAG_SUFFIX UBI_BASE_IMAGE PLATFORM BUILD_DIR QEMU_CPU MAX_GLIBC \
       SMOKE_TIMEOUT CONTROL_IMAGE LOCAL_IMAGE EXTRA_BUILD_FLAGS \
       OLM_REGISTRY OPM_RUN_ARGS REQUIRE_PUBLISHED_IMAGES FORCE_PUSH

S := scripts

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: submodules targets info
submodules: ## Initialise the pinned upstream submodules
	git submodule update --init

targets: ## List the targets (<image>/<version>) this repository can publish
	@source $(S)/lib.sh; list_targets

info: ## Print the resolved settings of TARGET
	@source $(S)/lib.sh; [[ -n "$${TARGET:-}" ]] || die "TARGET is not set (make targets)"; \
	  for v in TARGET MODE UPSTREAM_REPO UPSTREAM_REF SOURCE_IMAGE DOCKERFILE UBI_BASE_IMAGE PLATFORM LOCAL_IMAGE CONTROL_IMAGE; do \
	  printf '%-16s %s\n' "$$v" "$${!v:-}"; done; printf '%-16s %s\n' PUBLISH_TAGS "$${PUBLISH_TAGS[*]}"

# ---------------------------------------------------------------------------
# Build / verify / publish one TARGET
# ---------------------------------------------------------------------------
.PHONY: build verify verify-image verify-control push all
build: ## Build TARGET from upstream sources (MODE=build) or pull it (MODE=copy)
	$(S)/build-image.sh

verify: verify-image verify-control ## Checks a-c on TARGET's image, then d on the control image

verify-image: ## a-c: RHEL 9, GLIBC <= MAX_GLIBC, runs under qemu -cpu QEMU_CPU
	@mkdir -p $(WORK); source $(S)/lib.sh; $(S)/verify-image.sh "$$LOCAL_IMAGE" 2>&1 | tee $(WORK)/verify.log

verify-control: ## d: the same execution test must fail on CONTROL_IMAGE (UBI 10)
	@mkdir -p $(WORK); source $(S)/lib.sh; $(S)/verify-image.sh --control "$$CONTROL_IMAGE" 2>&1 | tee $(WORK)/control.log

push: ## Publish TARGET (needs a passed `make verify` and docker login)
	$(S)/push-image.sh

all: build verify push ## build + verify + push for TARGET

# ---------------------------------------------------------------------------
# OLM bundles and catalog (bundles/<package>/<version>.env)
# ---------------------------------------------------------------------------
.PHONY: bundles olm-bundles olm-push-bundles olm-catalog olm-verify olm-push-catalog olm
bundles: ## List the OLM bundles (<package>/<version>)
	@source $(S)/lib.sh; list_bundles

olm-bundles: ## Build the bundles: upstream community bundle with the GHCR operator image
	$(S)/olm-bundle.sh build

olm-push-bundles: ## Push the bundles to OLM_REGISTRY (unchanged content is not pushed again)
	$(S)/olm-bundle.sh push

olm-catalog: ## Render and validate the catalog of the pushed bundles, build the catalog image
	$(S)/olm-catalog.sh build

olm-verify: ## Catalog image on x86-64-v2 (ISA, qemu, gRPC) and every operator image it deploys
	@mkdir -p $(BUILD_DIR)/olm; $(S)/olm-catalog.sh verify 2>&1 | tee $(BUILD_DIR)/olm/verify.log

olm-push-catalog: ## Push the catalog image (:latest and :<date>-<content hash>)
	$(S)/olm-catalog.sh push

olm: olm-bundles olm-push-bundles olm-catalog olm-verify olm-push-catalog ## Whole OLM pipeline

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
.PHONY: lint check check-public clean
lint: ## shellcheck and python syntax
	shellcheck -x $(S)/*.sh
	python3 -m py_compile $(S)/*.py

check: lint ## lint + every target's submodule pin, patches and Dockerfile, bundle settings (needs network)
	$(S)/check-targets.sh
	$(S)/olm-bundle.sh check

check-public: ## Report whether the published tags can be pulled anonymously
	@$(S)/check-public.sh

clean: ## Remove build/
	rm -rf -- "$(BUILD_DIR)"
