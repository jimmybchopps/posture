# Pinned tool versions. CI reads these too; change them here only.
HELM_VERSION          ?= 4.3.1
HELM_MIN_VERSION      := 3.14.4
HELM3_LATEST_VERSION  := 3.22.1
HELM_UNITTEST_VERSION := 1.2.1
# helm-unittest 1.1.0+ uses plugin.yaml fields (platformHooks) that Helm 3.14 can't parse;
# 1.0.3 is the last release it loads.
HELM_UNITTEST_LEGACY_VERSION := 1.0.3
KUBECONFORM_VERSION   := 0.8.0
K3D_VERSION           := 5.9.0
KUBECTL_VERSION       := 1.37.2
# e2e (test/e2e/run.sh)
K3S_IMAGE             := rancher/k3s:v1.37.2-k3s1
CALICO_VERSION        := 3.29.0
# Istio Helm chart version for `make e2e MESH=istio`; installed by install_istio in test/e2e/lib.sh.
ISTIO_VERSION         := 1.32.0
# Images by digest: e2e enforces the policy chart's require-image-digest, so Istio is installed
# as a site running it would (istiod and ztunnel images, and the gateways' and waypoints' proxy).
ISTIO_PILOT_IMAGE     := docker.io/istio/pilot:$(ISTIO_VERSION)-distroless@sha256:219ab7efcf1fd1f883086ad4a4a649c0e70bee3200423d6eef9f435103a79423
ISTIO_PROXY_IMAGE     := docker.io/istio/proxyv2:$(ISTIO_VERSION)-distroless@sha256:9cd1f1cc261f3fe250ab483543e7256c39d5871eae5f1817c0809eff09e365d4
ISTIO_ZTUNNEL_IMAGE   := docker.io/istio/ztunnel:$(ISTIO_VERSION)-distroless@sha256:953a77fc17379301de4b7c6697b1668471c9c1f6ff912c9c5b78f454ab362180
AGNHOST_IMAGE         := registry.k8s.io/e2e-test-images/agnhost:2.61@sha256:101f3357d1ad890c3090e78ea6c6a47dc5137cbe19836796e13d5dcb2b84d2e6
CURL_IMAGE            := docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
# The Kubernetes Gateway API CRDs (standard channel), boundary's prerequisite: installed before
# Istio under MESH=istio.
GATEWAY_API_VERSION   := 1.6.0
GATEWAY_API_SHA256    := a557172e8348f758479e9ee4000bbbb4b4aa48302a6b73461823ea5349bad56d
MESH                  ?= none
# The policy chart release posture pins to: its PolicyExceptions CRD (kubeconform, e2e) and its
# chart package (e2e only). Checksums from the release's SHA256SUMS; bump all three together.
POLICY_VERSION        := 0.2.1
POLICY_CRD_SHA256     := 0b1c6cba6754d0135454d6f7f737f49b7f833f4ee0e7d37315654117821781be
POLICY_CHART_SHA256   := 20a1d1789fc954f59192c9ca6d23a03db3e3531ab4080f60a7bc74e3a20c6e70
# The boundary chart release e2e installs under MESH=istio (the gateways and the egress
# waypoint). Checksum from the release's SHA256SUMS; bump both together.
BOUNDARY_VERSION      := 0.1.1
BOUNDARY_CHART_SHA256 := 4c2d3b112528551d38e1f5331f69ed9b0602bdefcd3886ce2d735f28f9079619

# Every Helm version this chart supports; `make test-all-helm` runs the suite under each.
HELM_VERSIONS := $(HELM_MIN_VERSION) $(HELM3_LATEST_VERSION) $(HELM_VERSION)

CHART    := charts/posture
# Test-only chart that renders posture's model so tests can assert on it (test/model-probe).
PROBE    := test/model-probe
EXAMPLES := $(wildcard examples/*.yaml)
CRDS_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

BIN       := $(CURDIR)/.bin
HELM_HOME := $(BIN)/helm-$(HELM_VERSION)
HELM      := $(HELM_HOME)/helm
KUBECONFORM := $(BIN)/kubeconform-$(KUBECONFORM_VERSION)
K3D       := $(BIN)/k3d-$(K3D_VERSION)
KUBECTL   := $(BIN)/kubectl-$(KUBECTL_VERSION)

# Each Helm version gets its own plugin, cache, config, and data directories, so Helm 3 and
# Helm 4 never share plugin installs.
export HELM_PLUGINS     := $(HELM_HOME)/plugins
export HELM_CACHE_HOME  := $(HELM_HOME)/cache
export HELM_CONFIG_HOME := $(HELM_HOME)/config
export HELM_DATA_HOME   := $(HELM_HOME)/data

# The pinned policy release (make policy-release), and the JSON schema kubeconform checks
# posture-exceptions against, generated from its CRD by test/crd-schema (make crd-schema).
POLICY_DIR   := $(BIN)/policy-$(POLICY_VERSION)
POLICY_URL   := https://github.com/jimmybchopps/policy/releases/download/v$(POLICY_VERSION)
POLICY_CRD   := $(POLICY_DIR)/policy.posture.dev_policyexceptions.yaml
POLICY_CHART := $(POLICY_DIR)/policy-$(POLICY_VERSION).tgz
SCHEMAS      := $(BIN)/schemas-policy-$(POLICY_VERSION)
CRD_SCHEMA   := $(SCHEMAS)/policy.posture.dev/policyexceptions_v1alpha1.json

# The pinned boundary release (make boundary-release) and Gateway API CRDs, for e2e only.
BOUNDARY_CHART   := $(BIN)/boundary-$(BOUNDARY_VERSION)/boundary-$(BOUNDARY_VERSION).tgz
GATEWAY_API_CRDS := $(BIN)/gateway-api-$(GATEWAY_API_VERSION)/standard-install.yaml

UNITTEST_PLUGIN := $(HELM_PLUGINS)/helm-unittest
UNITTEST_VERSION := $(if $(filter 3.14.%,$(HELM_VERSION)),$(HELM_UNITTEST_LEGACY_VERSION),$(HELM_UNITTEST_VERSION))
# helm-unittest only reads tests/*_test.yaml by default; the suites are grouped by output in
# subfolders (tests/networkpolicy/, tests/istio/), so name both levels.
UNITTEST_FILES := -f 'tests/*_test.yaml' -f 'tests/*/*_test.yaml'

.PHONY: help tools tools-e2e policy-release boundary-release crd-schema lint unittest unittest-update validate check-release release-check test test-all-helm e2e clean

help:
	@echo "make tools          install helm $(HELM_VERSION), helm-unittest, kubeconform into .bin/"
	@echo "make test           lint, unittest, validate, check-release"
	@echo "make test-all-helm  make test under Helm $(HELM_VERSIONS)"
	@echo "make e2e MESH=none  k3d end-to-end tests (MESH=istio too); E2E_KEEP=1 keeps the cluster"
	@echo "make unittest-update  regenerate example snapshots (review the diff)"
	@echo "make policy-release   fetch and verify the pinned policy chart $(POLICY_VERSION) (CRD and package)"
	@echo "make boundary-release fetch and verify the pinned boundary chart $(BOUNDARY_VERSION) and Gateway API CRDs (e2e)"
	@echo "make release-check TAG=v<version>  build a release's assets into dist/, as the release workflow does"
	@echo "HELM_VERSION=x.y.z selects the Helm version for any target."

tools: $(HELM) $(UNITTEST_PLUGIN) $(KUBECONFORM)

tools-e2e: $(K3D) $(KUBECTL)

$(HELM):
	mkdir -p $(HELM_HOME)
	curl -fsSL https://get.helm.sh/helm-v$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -C $(HELM_HOME) --strip-components=1 $(OS)-$(ARCH)/helm

# Helm 4 verifies plugin sources by default and helm-unittest isn't signed; Helm 3 has no
# --verify flag at all.
$(UNITTEST_PLUGIN): $(HELM)
	$(HELM) plugin install https://github.com/helm-unittest/helm-unittest \
	  --version $(UNITTEST_VERSION) \
	  $(if $(filter 4.%,$(HELM_VERSION)),--verify=false)

$(KUBECONFORM):
	mkdir -p $(BIN)
	curl -fsSL https://github.com/yannh/kubeconform/releases/download/v$(KUBECONFORM_VERSION)/kubeconform-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -O kubeconform > $@
	chmod +x $@

$(K3D):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://github.com/k3d-io/k3d/releases/download/v$(K3D_VERSION)/k3d-$(OS)-$(ARCH)
	chmod +x $@

$(KUBECTL):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://dl.k8s.io/release/v$(KUBECTL_VERSION)/bin/$(OS)/$(ARCH)/kubectl
	chmod +x $@

# Downloads are checked against the pinned checksums, so a moved tag can't change what's tested.
policy-release: $(POLICY_CRD) $(POLICY_CHART)

$(POLICY_CRD):
	mkdir -p $(POLICY_DIR)
	curl -fsSL -o $@.tmp $(POLICY_URL)/$(notdir $@)
	echo "$(POLICY_CRD_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

$(POLICY_CHART):
	mkdir -p $(POLICY_DIR)
	curl -fsSL -o $@.tmp $(POLICY_URL)/$(notdir $@)
	echo "$(POLICY_CHART_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

boundary-release: $(BOUNDARY_CHART) $(GATEWAY_API_CRDS)

$(BOUNDARY_CHART):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/jimmybchopps/boundary/releases/download/v$(BOUNDARY_VERSION)/$(notdir $@)
	echo "$(BOUNDARY_CHART_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

$(GATEWAY_API_CRDS):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/kubernetes-sigs/gateway-api/releases/download/v$(GATEWAY_API_VERSION)/standard-install.yaml
	echo "$(GATEWAY_API_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

# The chart is assembled in .bin/ because a chart can only read its own files.
crd-schema: $(CRD_SCHEMA)

$(CRD_SCHEMA): $(POLICY_CRD) $(wildcard test/crd-schema/* test/crd-schema/templates/*) | $(HELM)
	rm -rf $(BIN)/crd-schema-chart
	cp -r test/crd-schema $(BIN)/crd-schema-chart
	cp $(POLICY_CRD) $(BIN)/crd-schema-chart/crd.yaml
	mkdir -p $(dir $@)
	$(HELM) template x $(BIN)/crd-schema-chart --show-only templates/schema.yaml \
	  | sed -e '/^---/d' -e '/^# Source/d' -e '/^$$/d' > $@

# The unquoted-date file is linted here because helm-unittest reads unquoted dates as
# timestamps, while Helm keeps them strings (exceptions.*.policies.*.expires: 2027-03-31).
lint: $(HELM)
	$(HELM) lint --strict $(CHART)
	$(HELM) lint --strict $(CHART) -f $(CHART)/tests/values/exceptions-unquoted-date.yaml
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> helm lint --strict -f $$f"; \
	  $(HELM) lint --strict $(CHART) -f $$f; \
	done

unittest: $(UNITTEST_PLUGIN)
	$(HELM) dependency update --skip-refresh $(PROBE) >/dev/null
	$(HELM) unittest $(UNITTEST_FILES) $(CHART) $(PROBE)

# Regenerate the example snapshots after an intended change; review the diff before committing.
unittest-update: $(UNITTEST_PLUGIN)
	$(HELM) unittest -u $(UNITTEST_FILES) $(CHART)

validate: $(HELM) $(KUBECONFORM) $(CRD_SCHEMA)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> kubeconform $$f"; \
	  $(HELM) template posture $(CHART) -f $$f \
	    | $(KUBECONFORM) -strict -summary \
	        -schema-location default \
	        -schema-location '$(SCHEMAS)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
	        -schema-location '$(CRDS_CATALOG)'; \
	done

# The release scripts' own cases (test/release/tag-cases/): a tag must match Chart.yaml and a
# CHANGELOG.md section that is no longer marked (unreleased).
check-release:
	@test/release/run-cases.sh

# Builds a release's assets into dist/ exactly as .github/workflows/release.yml does
# (test/release/build-dist.sh), so a release can be rehearsed before tagging:
#   make release-check TAG=v0.1.0
release-check: $(HELM)
	@test -n "$(TAG)" || { echo "usage: make release-check TAG=v<version>"; exit 1; }
	@HELM=$(HELM) test/release/build-dist.sh $(TAG) dist

test: lint unittest validate check-release

test-all-helm:
	@set -e; for v in $(HELM_VERSIONS); do \
	  echo "==> Helm $$v"; \
	  $(MAKE) --no-print-directory test HELM_VERSION=$$v; \
	done

# Needs Docker. Extra arguments go to run.sh via E2E_ARGS (e.g. E2E_ARGS=strict).
e2e: $(HELM) tools-e2e policy-release boundary-release
	K3D=$(K3D) KUBECTL=$(KUBECTL) HELM=$(HELM) \
	POLICY_CRD=$(POLICY_CRD) POLICY_CHART=$(POLICY_CHART) \
	BOUNDARY_CHART=$(BOUNDARY_CHART) GATEWAY_API_CRDS=$(GATEWAY_API_CRDS) \
	K3S_IMAGE=$(K3S_IMAGE) CALICO_VERSION=$(CALICO_VERSION) ISTIO_VERSION=$(ISTIO_VERSION) \
	ISTIO_PILOT_IMAGE=$(ISTIO_PILOT_IMAGE) ISTIO_PROXY_IMAGE=$(ISTIO_PROXY_IMAGE) \
	ISTIO_ZTUNNEL_IMAGE=$(ISTIO_ZTUNNEL_IMAGE) \
	AGNHOST_IMAGE=$(AGNHOST_IMAGE) CURL_IMAGE=$(CURL_IMAGE) \
	  test/e2e/run.sh $(MESH) $(E2E_ARGS)

clean:
	rm -rf $(BIN)
