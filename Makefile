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
CALICO_VERSION        := 3.33.0
# Istio Helm chart version for `make e2e MESH=istio`; installed by install_istio in test/e2e/lib.sh.
ISTIO_VERSION         := 1.31.4
AGNHOST_IMAGE         := registry.k8s.io/e2e-test-images/agnhost:2.61
CURL_IMAGE            := curlimages/curl:8.23.0
MESH                  ?= none

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

UNITTEST_PLUGIN := $(HELM_PLUGINS)/helm-unittest
UNITTEST_VERSION := $(if $(filter 3.14.%,$(HELM_VERSION)),$(HELM_UNITTEST_LEGACY_VERSION),$(HELM_UNITTEST_VERSION))

.PHONY: help tools tools-e2e lint unittest unittest-update validate test test-all-helm e2e clean

help:
	@echo "make tools          install helm $(HELM_VERSION), helm-unittest, kubeconform into .bin/"
	@echo "make test           lint, unittest, validate"
	@echo "make test-all-helm  make test under Helm $(HELM_VERSIONS)"
	@echo "make e2e MESH=none  k3d end-to-end tests (MESH=istio too); E2E_KEEP=1 keeps the cluster"
	@echo "make unittest-update  regenerate example snapshots (review the diff)"
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

lint: $(HELM)
	$(HELM) lint --strict $(CHART)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> helm lint --strict -f $$f"; \
	  $(HELM) lint --strict $(CHART) -f $$f; \
	done

unittest: $(UNITTEST_PLUGIN)
	$(HELM) dependency update --skip-refresh $(PROBE) >/dev/null
	$(HELM) unittest $(CHART) $(PROBE)

# Regenerate the example snapshots after an intended change; review the diff before committing.
unittest-update: $(UNITTEST_PLUGIN)
	$(HELM) unittest -u $(CHART)

validate: $(HELM) $(KUBECONFORM)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> kubeconform $$f"; \
	  $(HELM) template posture $(CHART) -f $$f \
	    | $(KUBECONFORM) -strict -summary \
	        -schema-location default -schema-location '$(CRDS_CATALOG)'; \
	done

test: lint unittest validate

test-all-helm:
	@set -e; for v in $(HELM_VERSIONS); do \
	  echo "==> Helm $$v"; \
	  $(MAKE) --no-print-directory test HELM_VERSION=$$v; \
	done

# Needs Docker. Extra arguments go to run.sh via E2E_ARGS (e.g. E2E_ARGS=strict).
e2e: $(HELM) tools-e2e
	K3D=$(K3D) KUBECTL=$(KUBECTL) HELM=$(HELM) \
	K3S_IMAGE=$(K3S_IMAGE) CALICO_VERSION=$(CALICO_VERSION) ISTIO_VERSION=$(ISTIO_VERSION) \
	AGNHOST_IMAGE=$(AGNHOST_IMAGE) CURL_IMAGE=$(CURL_IMAGE) \
	  test/e2e/run.sh $(MESH) $(E2E_ARGS)

clean:
	rm -rf $(BIN)
