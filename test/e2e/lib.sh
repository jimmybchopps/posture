#!/usr/bin/env bash
# Helpers for the posture e2e tests. Sourced by run.sh; expects MESH, CLUSTER, ROOT, and the
# tool variables (K3D, KUBECTL, HELM) and image variables to be set.

# ---------------------------------------------------------------------------------------------
# Output

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PASSED=0
FAILED=0
FAILURES=()

record() { # record <PASS|FAIL> <message>
  printf '%s %s\n' "$1" "$2"
  if [[ $1 == PASS ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILURES+=("$2")
  fi
}

summary() {
  log "summary: ${PASSED} passed, ${FAILED} failed"
  local f
  for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
  [[ $FAILED -eq 0 ]]
}

# ---------------------------------------------------------------------------------------------
# Cluster

create_cluster() {
  log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE}, flannel and k3s network policy disabled)"
  "$K3D" cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents 1 \
    --k3s-arg '--flannel-backend=none@server:*' \
    --k3s-arg '--disable-network-policy@server:*' \
    --k3s-arg '--disable=traefik@server:*' \
    --wait
}

delete_cluster() {
  "$K3D" cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}

# Calico from the upstream manifest, adjusted for k3s: the pod CIDR k3s assigns, IP forwarding
# in containers, and k3s's CNI directories instead of /etc/cni/net.d and /opt/cni/bin.
# NOTE: not yet run against a real cluster (the dev environment can't run Docker); the k3s CNI
# paths are the likeliest thing to need adjusting.
install_cni() {
  log "installing Calico ${CALICO_VERSION}"
  local manifest
  manifest=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml" -o "$manifest" \
    || die "can't download the Calico ${CALICO_VERSION} manifest"
  sed -i \
    -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
    -e 's|#   value: "192.168.0.0/16"|  value: "10.42.0.0/16"|' \
    -e 's|"type": "calico",|"type": "calico", "container_settings": { "allow_ip_forwarding": true },|' \
    -e 's|path: /etc/cni/net.d|path: /var/lib/rancher/k3s/agent/etc/cni/net.d|' \
    -e 's|path: /opt/cni/bin|path: /var/lib/rancher/k3s/data/cni|' \
    "$manifest"
  "$KUBECTL" apply -f "$manifest" >/dev/null
  rm -f "$manifest"
  "$KUBECTL" -n kube-system rollout status daemonset/calico-node --timeout=300s
  "$KUBECTL" -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s
  "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=300s
}

# Istio ambient on k3d. Called by run.sh only when MESH=istio, after install_cni (Calico is
# up and CoreDNS is ready) and before any scenario runs.
#
# TODO(istio): add the Istio Helm chart installation here. Everything it needs is already set:
#   - "$HELM" and "$KUBECTL" are the pinned binaries (use them, not whatever is on PATH).
#   - ISTIO_VERSION is pinned in the Makefile (ISTIO_VERSION := ...) and passed in by `make e2e`;
#     bump it there, not here. Use it as --version on every chart so they stay in step.
#   - The kube context already points at the k3d cluster.
#
# Where the configuration goes:
#   - Chart values: inline --set flags here, or, if they grow, values files in a new
#     test/e2e/istio/ directory (e.g. test/e2e/istio/cni.yaml), passed with
#     -f "$HERE/istio/cni.yaml". $HERE is test/e2e.
#   - istio-cni's CNI directories must match the ones install_cni gives Calico above
#     (conf: /var/lib/rancher/k3s/agent/etc/cni/net.d, bin: /var/lib/rancher/k3s/data/cni).
#     If you change one, change the other. Neither has been run on a real cluster.
#
# What the rest of the harness expects once this returns:
#   - The ambient data plane is running and ready (ztunnel on every node, istio-cni ready),
#     so a namespace labeled istio.io/dataplane-mode=ambient is meshed straight away.
#     namespace() in this file adds that label to every test namespace when MESH=istio.
#   - Kubelet probes arrive from 169.254.7.127 (the ambient default). posture's
#     allow-ingress-from-ambient-probes-to-all policy allows that address, and the
#     grafana-prometheus scenario's `extra` step depends on it.
#   - No waypoints and no egress gateway are needed: posture is L4 only in Phase 1.
#
# A possible outline (not verified, adjust to your setup):

install_istio() {
  log "installing Istio ${ISTIO_VERSION} (ambient)"
  "$HELM" repo add istio https://istio-release.storage.googleapis.com/charts
  "$HELM" install istio-base istio/base     -n istio-system --create-namespace --version "$ISTIO_VERSION" --wait
  "$HELM" install istiod     istio/istiod   -n istio-system --version "$ISTIO_VERSION" --set profile=ambient --wait
  "$HELM" install istio-cni  istio/cni      -n istio-system --version "$ISTIO_VERSION" --set profile=ambient --set global.platform=k3s --wait
  "$HELM" install ztunnel    istio/ztunnel  -n istio-system --version "$ISTIO_VERSION" --wait
  "$KUBECTL" -n istio-system rollout status daemonset/istio-cni-node --timeout=300s
  "$KUBECTL" -n istio-system rollout status daemonset/ztunnel --timeout=300s
}

# ---------------------------------------------------------------------------------------------
# The external host: a container on the k3d Docker network, outside the cluster, on an address
# inside the private ranges (172.16.0.0/12), so the postgres/sso presets match it for real.

EXT_IP=""

start_external() {
  log "starting the external host"
  docker rm -f "${CLUSTER}-external" >/dev/null 2>&1 || true
  docker run -d --name "${CLUSTER}-external" --network "k3d-${CLUSTER}" \
    -e SERVE_PORT_443=external-443 -e SERVE_PORT_5432=external-5432 \
    -e SERVE_PORT_8443=external-8443 -e SERVE_PORT_8080=external-8080 \
    "$AGNHOST_IMAGE" porter >/dev/null
  EXT_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-external")
  [[ -n $EXT_IP ]] || die "the external host has no IP address"
  printf 'external host: %s\n' "$EXT_IP"
}

stop_external() {
  docker rm -f "${CLUSTER}-external" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
# Namespaces and workloads

NAMESPACES=()

namespace() { # namespace <name>: created fresh; in the ambient mesh when MESH=istio
  local ns=$1
  "$KUBECTL" create namespace "$ns" >/dev/null
  if [[ $MESH == istio ]]; then
    "$KUBECTL" label namespace "$ns" istio.io/dataplane-mode=ambient >/dev/null
  fi
  NAMESPACES+=("$ns")
}

# workload <namespace> <name> <port>...
# A Deployment labeled app.kubernetes.io/name=<name>, with a server container (agnhost porter,
# HTTP on every port, readiness probe on the first) and a client container (curl), plus a
# Service <name>.<namespace> on the same ports.
workload() {
  local ns=$1 name=$2
  shift 2
  local env="" svc_ports="" port
  for port in "$@"; do
    env+="
            - { name: SERVE_PORT_${port}, value: ${name}-${port} }"
    svc_ports+="
    - { name: p${port}, port: ${port}, targetPort: ${port} }"
  done
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${name}, namespace: ${ns} }
spec:
  replicas: 1
  selector: { matchLabels: { app.kubernetes.io/name: ${name} } }
  template:
    metadata: { labels: { app.kubernetes.io/name: ${name} } }
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: server
          image: ${AGNHOST_IMAGE}
          args: [porter]
          env: ${env}
          readinessProbe:
            tcpSocket: { port: $1 }
            periodSeconds: 2
        - name: client
          image: ${CURL_IMAGE}
          command: [sleep, infinity]
---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: ${ns} }
spec:
  selector: { app.kubernetes.io/name: ${name} }
  ports: ${svc_ports}
EOF
}

wait_ready() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    "$KUBECTL" -n "$ns" wait --for=condition=Available deployment --all --timeout=180s >/dev/null
  done
}

# install_posture <namespace> <example file under examples/>
install_posture() {
  local ns=$1 example=$2
  "$HELM" install posture "$ROOT/charts/posture" -n "$ns" \
    -f "$ROOT/examples/${example}" --set "mesh=${MESH}" --wait >/dev/null
}

cleanup_namespaces() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    "$HELM" uninstall posture -n "$ns" >/dev/null 2>&1 || true
    "$KUBECTL" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  done
  for ns in "${NAMESPACES[@]}"; do
    "$KUBECTL" wait --for=delete "namespace/$ns" --timeout=120s >/dev/null 2>&1 || true
  done
  NAMESPACES=()
}

# ---------------------------------------------------------------------------------------------
# Checks
#
# Scenarios declare checks with `expect allow|deny <namespace>/<workload> <host>:<port>`.
# run_checks then runs them: every allow first (retried while policies propagate), then every
# deny (retried until the connection fails, so a policy that's still being programmed doesn't
# count as a pass). A deny is "no HTTP response": under Istio ambient a blocked connection can
# be reset by ztunnel instead of timing out.

ALLOWS=()
DENIES=()

expect() { # expect <allow|deny> <ns>/<workload> <host>:<port>
  case $1 in
    allow) ALLOWS+=("$2 $3") ;;
    deny) DENIES+=("$2 $3") ;;
    *) die "expect: unknown expectation $1" ;;
  esac
}

connect() { # connect <ns>/<workload> <host>:<port>; succeeds on an HTTP response
  local ns=${1%%/*} name=${1#*/}
  "$KUBECTL" -n "$ns" exec "deploy/${name}" -c client -- \
    curl -sS -o /dev/null -m 3 "http://$2/" >/dev/null 2>&1
}

retry_until() { # retry_until <want: up|down> <from> <to>
  local want=$1 _attempt
  for _attempt in 1 2 3 4 5 6; do
    if connect "$2" "$3"; then
      [[ $want == up ]] && return 0
    else
      [[ $want == down ]] && return 0
    fi
    sleep 2
  done
  return 1
}

# run_checks <phase>: "baseline" (no posture yet: everything must connect) or "policy"
run_checks() {
  local phase=$1 check from to
  for check in "${ALLOWS[@]}"; do
    read -r from to <<<"$check"
    if retry_until up "$from" "$to"; then
      record PASS "[$phase] allow $from -> $to"
    else
      record FAIL "[$phase] allow $from -> $to"
    fi
  done
  for check in "${DENIES[@]}"; do
    read -r from to <<<"$check"
    if [[ $phase == baseline ]]; then
      if retry_until up "$from" "$to"; then
        record PASS "[baseline] reachable before posture: $from -> $to"
      else
        record FAIL "[baseline] reachable before posture: $from -> $to (the deny check below would prove nothing)"
      fi
    elif retry_until down "$from" "$to"; then
      record PASS "[$phase] deny $from -> $to"
    else
      record FAIL "[$phase] deny $from -> $to"
    fi
  done
}

# run_scenario <name>: sources scenarios/<name>.sh, which defines setup, install, and checks
# (and optionally extra, for checks that aren't connections).
run_scenario() {
  local name=$1 before=$FAILED
  log "scenario ${name} (mesh: ${MESH})"
  unset -f setup install checks extra
  # shellcheck source=/dev/null
  source "${HERE}/scenarios/${name}.sh"
  ALLOWS=()
  DENIES=()
  setup
  wait_ready
  checks
  run_checks baseline
  install
  run_checks policy
  if declare -F extra >/dev/null; then extra; fi
  if [[ $FAILED -gt $before ]]; then dump_state; fi
  cleanup_namespaces
}

dump_state() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    printf '\n--- namespace %s\n' "$ns"
    "$KUBECTL" -n "$ns" get pods -o wide || true
    "$KUBECTL" -n "$ns" get networkpolicies -o yaml || true
  done
}
