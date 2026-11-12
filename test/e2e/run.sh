#!/usr/bin/env bash
# posture e2e tests on k3d with Calico: allowed traffic connects, denied traffic doesn't.
#
# Usage: test/e2e/run.sh <none|istio> [scenario...]
#   Normally run through `make e2e MESH=none|istio`, which installs the pinned tools and sets
#   the variables below.
#
# Environment:
#   K3D, KUBECTL, HELM               tool binaries (default: from PATH)
#   K3S_IMAGE, CALICO_VERSION,
#   ISTIO_VERSION, AGNHOST_IMAGE,
#   CURL_IMAGE                       pinned versions (set by the Makefile)
#   POLICY_CRD, POLICY_CHART         the pinned policy release's PolicyExceptions CRD and chart
#                                    package (make policy-release)
#   E2E_CLUSTER                      cluster name (default posture-e2e)
#   E2E_KEEP=1                       keep the cluster and external host afterwards
#   E2E_REUSE=1                      use an existing cluster of that name (skips setup)
set -euo pipefail

MESH=${1:?usage: run.sh <none|istio> [scenario...]}
shift
[[ $MESH == none || $MESH == istio ]] || { echo "unknown mesh: $MESH" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CLUSTER=${E2E_CLUSTER:-posture-e2e}
K3D=${K3D:-k3d}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
: "${K3S_IMAGE:?set K3S_IMAGE (make e2e sets it)}"
: "${CALICO_VERSION:?set CALICO_VERSION}"
: "${ISTIO_VERSION:?set ISTIO_VERSION}"
: "${AGNHOST_IMAGE:?set AGNHOST_IMAGE}"
: "${CURL_IMAGE:?set CURL_IMAGE}"
: "${POLICY_CRD:?set POLICY_CRD (make e2e sets it)}"
: "${POLICY_CHART:?set POLICY_CHART (make e2e sets it)}"
export MESH HERE ROOT CLUSTER K3D KUBECTL HELM POLICY_CRD POLICY_CHART

# shellcheck source=test/e2e/lib.sh
source "$HERE/lib.sh"

teardown() {
  if [[ ${E2E_KEEP:-0} == 1 ]]; then
    log "keeping cluster ${CLUSTER} (E2E_KEEP=1); delete it with: $K3D cluster delete ${CLUSTER}"
  else
    stop_external
    delete_cluster
  fi
}
trap teardown EXIT

if [[ ${E2E_REUSE:-0} == 1 ]]; then
  log "reusing cluster ${CLUSTER}"
  "$K3D" kubeconfig merge "$CLUSTER" --kubeconfig-switch-context >/dev/null
else
  delete_cluster
  create_cluster
  install_cni
  # TODO(istio): the Istio Helm installation goes in install_istio (test/e2e/lib.sh).
  if [[ $MESH == istio ]]; then install_istio; fi
fi
# Every posture install renders posture-exceptions, so the PolicyExceptions CRD must exist. On
# its own it changes nothing; only the exceptions scenario installs the policies that read it.
quiet "$KUBECTL" apply -f "$POLICY_CRD"
quiet "$KUBECTL" wait --for=condition=Established crd/policyexceptions.policy.posture.dev --timeout=60s
start_external
export EXT_IP

scenarios=("$@")
if [[ ${#scenarios[@]} -eq 0 ]]; then
  scenarios=(minimal strict grafana-prometheus identity identity-authz-only identity-netpol-only mtls-strict mtls-permissive exceptions)
fi
for s in "${scenarios[@]}"; do
  run_scenario "$s"
  if [[ -n $KEPT_SCENARIO ]]; then break; fi
done

summary
