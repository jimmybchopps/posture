#!/usr/bin/env bash
# Helpers for the posture e2e tests. Sourced by run.sh; expects MESH, CLUSTER, ROOT, and the
# tool variables (K3D, KUBECTL, HELM) and image variables to be set.

# ---------------------------------------------------------------------------------------------
# Output

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quiet() { # quiet <command...>: runs it silently; prints its output only if it fails
  local out
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

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

SKIPPED=()

summary() {
  log "summary: ${PASSED} passed, ${FAILED} failed${SKIPPED[*]:+, scenarios skipped for this mesh: ${SKIPPED[*]}}"
  local f
  for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
  [[ $FAILED -eq 0 ]]
}

# ---------------------------------------------------------------------------------------------
# Cluster

create_cluster() {
  log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE}, flannel and k3s network policy disabled)"
  quiet "$K3D" cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents 1 \
    --k3s-arg '--flannel-backend=none@server:*' \
    --k3s-arg '--disable-network-policy@server:*' \
    --k3s-arg '--cluster-cidr=192.168.0.0/16@server:*' \
    --k3s-arg '--disable=traefik@server:*' \
    --wait
}

delete_cluster() {
  "$K3D" cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}

# Calico through the Tigera operator, following k3d's guide as closely as possible:
# https://k3d.io/v5.9.0/usage/advanced/calico/
# The upstream custom-resources.yaml is applied unmodified; its IP pool (192.168.0.0/16) matches
# the --cluster-cidr that create_cluster passes to k3s. If you change one, change the other.
install_cni() {
  log "installing Calico ${CALICO_VERSION} (Tigera operator)"
  quiet "$KUBECTL" create -f "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/tigera-operator.yaml"
  quiet "$KUBECTL" create -f "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/custom-resources.yaml"
  info "operator and custom resources created; waiting for Calico"
  # The guide's "kubectl get tigerastatus" check, as a wait. The status object only appears once
  # the operator has picked up the Installation, so wait for it to exist first.
  quiet "$KUBECTL" wait --for=create tigerastatus/calico --timeout=120s
  quiet "$KUBECTL" wait --for=condition=Available tigerastatus/calico --timeout=180s
  quiet "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=120s
  info "Calico and CoreDNS are ready"
}

# Istio ambient, under the policy chart (installed first, see install_policy_chart): istiod and
# ztunnel in istio-system, whose posture-exceptions install_platform_exceptions has already
# rendered; istio-cni in kube-system (required on GKE, and Istio's preferred alternative to
# istio-system), which the policies never evaluate.
install_istio() {
  log "installing Istio ${ISTIO_VERSION} (ambient)"
  quiet "$HELM" repo add istio https://blob.istio.io/istio-release/charts --force-update
  istio_chart istio-system istio-base base
  istio_chart istio-system istiod     istiod  --set profile=ambient
  istio_chart kube-system  istio-cni  cni     --set profile=ambient
  istio_chart istio-system ztunnel    ztunnel
  quiet "$KUBECTL" -n kube-system rollout status daemonset/istio-cni-node --timeout=300s ||
    { refused_pods kube-system; return 1; }
  quiet "$KUBECTL" -n istio-system rollout status daemonset/ztunnel --timeout=300s ||
    { refused_pods istio-system; return 1; }
  info "istio-cni and ztunnel are ready on every node"
}

istio_chart() { # istio_chart <namespace> <release> <chart> [helm args...]
  local ns=$1 release=$2 chart=$3
  shift 3
  if ! quiet "$HELM" install "$release" "istio/$chart" -n "$ns" --version "$ISTIO_VERSION" --wait "$@"; then
    refused_pods "$ns"
    return 1
  fi
  info "${release} installed in ${ns}"
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

# namespace <name>: created fresh; in the ambient mesh when MESH=istio, unless MESHED=0 (a
# namespace outside the mesh, whose clients send plaintext), e.g. MESHED=0 namespace plain
namespace() {
  local ns=$1
  "$KUBECTL" create namespace "$ns" >/dev/null
  if [[ $MESH == istio && ${MESHED:-1} != 0 ]]; then
    "$KUBECTL" label namespace "$ns" istio.io/dataplane-mode=ambient >/dev/null
  fi
  # Under the policy chart, pods are denied until posture-exceptions exists (fail closed), and
  # the baseline checks run before the scenario's posture values apply. As on a real cluster,
  # posture is the namespace's first release; install_posture upgrades it later.
  if [[ $POLICY_INSTALLED == 1 ]]; then posture_first "$ns"; fi
  NAMESPACES+=("$ns")
}

# workload <namespace> <name> <port>...
# A Deployment whose pods are labeled app.kubernetes.io/name=<name> and run as the
# ServiceAccount <name>, with a server container (agnhost porter, HTTP on every port, readiness
# probe on the first) and a client container (curl), plus a Service <name>.<namespace> on the
# same ports. It meets the policy chart's baseline (non-root, RuntimeDefault seccomp, no
# privilege escalation, every capability dropped), under every mesh, so it's admitted whether
# or not the policy chart is installed.
#
# For an impostor, override with environment variables:
#   LABEL=<name>  pods carry app.kubernetes.io/name=<LABEL> instead; no Service is created
#                 (it would select the real workload's pods too)
#   SA=<name>     pods run as this ServiceAccount instead
# e.g. LABEL=web SA=impostor workload apps fake-web 8080
#
# The Deployment selects its pods by e2e.posture.dev/deployment=<name>, not by the name label,
# so an impostor's pods never count as the real workload's (kubectl exec deploy/<name> stays
# on the right pod).
workload() {
  local ns=$1 name=$2
  shift 2
  local label=${LABEL:-$name} sa=${SA:-$name}
  local env="" svc_ports="" port
  for port in "$@"; do
    env+="
            - { name: SERVE_PORT_${port}, value: ${name}-${port} }"
    svc_ports+="
    - { name: p${port}, port: ${port}, targetPort: ${port} }"
  done
  local service=""
  if [[ -z ${LABEL:-} ]]; then
    service="---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: ${ns} }
spec:
  selector: { app.kubernetes.io/name: ${name} }
  ports: ${svc_ports}"
  fi
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${sa}, namespace: ${ns} }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${name}, namespace: ${ns} }
spec:
  replicas: 1
  selector: { matchLabels: { e2e.posture.dev/deployment: ${name} } }
  template:
    metadata:
      labels: { app.kubernetes.io/name: ${label}, e2e.posture.dev/deployment: ${name} }
    spec:
      serviceAccountName: ${sa}
      terminationGracePeriodSeconds: 1
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: server
          image: ${AGNHOST_IMAGE}
          args: [porter]
          env: ${env}
          readinessProbe:
            tcpSocket: { port: $1 }
            periodSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
        - name: client
          image: ${CURL_IMAGE}
          command: [sleep, infinity]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
${service}
EOF
}

# has_deployments <namespace>: whether it has any (a scenario may use bare Pods only).
has_deployments() {
  [[ -n $("$KUBECTL" -n "$1" get deployment -o name) ]]
}

wait_ready() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    has_deployments "$ns" || continue
    "$KUBECTL" -n "$ns" wait --for=condition=Available deployment --all --timeout=180s >/dev/null
  done
}

# install_posture <namespace> <example file under examples/> [helm args...]
# Extra arguments go to helm install after the example, e.g. --set networkPolicy.ingress=false.
# Under the policy chart, the namespace already has a posture release (posture_first), so this
# upgrades it; --reset-values keeps nothing from that first release.
install_posture() {
  local ns=$1 example=$2
  shift 2
  local action=(install)
  if "$HELM" status posture -n "$ns" >/dev/null 2>&1; then action=(upgrade --reset-values); fi
  quiet "$HELM" "${action[@]}" posture "$ROOT/charts/posture" -n "$ns" \
    -f "$ROOT/examples/${example}" --set "mesh=${MESH}" "$@" --wait
  info "posture installed in ${ns} (examples/${example}${*:+ $*})"
}

# restart_workloads: replaces every pod in the scenario's namespaces and waits until only the
# new ones are left. Used under Istio ambient after posture is installed: ztunnel pools the
# HBONE connections the baseline checks opened and sends later requests over them, while
# NetworkPolicy only judges new connections, so without this every in-cluster deny would still
# connect. New pods have new addresses and no pooled connections. Restarting ztunnel itself
# would also drop the pool, but it briefly breaks all meshed traffic, which a deny check would
# count as a pass.
restart_workloads() {
  local ns d
  for ns in "${NAMESPACES[@]}"; do
    has_deployments "$ns" || continue
    quiet "$KUBECTL" -n "$ns" rollout restart deployment
  done
  for ns in "${NAMESPACES[@]}"; do
    for d in $("$KUBECTL" -n "$ns" get deployment -o name); do
      quiet "$KUBECTL" -n "$ns" rollout status "$d" --timeout=180s
    done
  done
  # kubectl exec deploy/<name> may pick a pod that's still terminating; wait until they're gone.
  local _attempt terminating
  for _attempt in $(seq 1 30); do
    terminating=""
    for ns in "${NAMESPACES[@]}"; do
      terminating+=$("$KUBECTL" -n "$ns" get pods -o jsonpath='{.items[*].metadata.deletionTimestamp}')
    done
    [[ -z $terminating ]] && break
    sleep 2
  done
  [[ -z $terminating ]] || die "old pods are still terminating after the restart"
  info "workloads restarted (drops connections ztunnel pooled during the baseline)"
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
# (and optionally extra, for checks that aren't connections, and teardown, which undoes
# anything setup did outside the scenario's namespaces; it runs before they're deleted).
run_scenario() {
  local name=$1 before=$FAILED
  log "scenario ${name} (mesh: ${MESH})"
  unset -f setup install checks extra teardown
  unset SCENARIO_MESHES
  # shellcheck source=/dev/null
  source "${HERE}/scenarios/${name}.sh"
  # A scenario may set SCENARIO_MESHES=(istio ...) to run only under those meshes.
  if [[ -n ${SCENARIO_MESHES+x} && " ${SCENARIO_MESHES[*]} " != *" ${MESH} "* ]]; then
    info "skipped: needs MESH=${SCENARIO_MESHES[*]}"
    SKIPPED+=("$name")
    return 0
  fi
  ALLOWS=()
  DENIES=()
  setup
  wait_ready
  checks
  run_checks baseline
  install
  if [[ $MESH == istio ]]; then restart_workloads; fi
  run_checks policy
  if declare -F extra >/dev/null; then extra; fi
  if [[ $FAILED -gt $before ]]; then
    dump_state
    if [[ ${E2E_KEEP:-0} == 1 ]]; then
      # Keep this scenario's namespaces to inspect; later scenarios may reuse their names, so stop.
      KEPT_SCENARIO=$name
      info "keeping namespaces ${NAMESPACES[*]} (E2E_KEEP=1); skipping the remaining scenarios"
      return 0
    fi
  fi
  if declare -F teardown >/dev/null; then teardown; fi
  cleanup_namespaces
}

# ---------------------------------------------------------------------------------------------
# Admission (policy exceptions)
#
# The pinned policy chart (POLICY_CHART) and its baked-in policies apply to every namespace but
# kube-system.
#   MESH=none:  only the exceptions scenario installs it, and uninstalls it in its teardown. Its
#               CRD stays (resource-policy: keep), as run.sh's copy must for every later
#               posture install.
#   otherwise:  POLICY_FIRST=1: run.sh installs it before the mesh, as a real cluster would, so
#               the mesh's own workloads are admitted against it; it stays for the whole run,
#               and the scenarios' install and uninstall calls do nothing.

POLICY_FIRST=${POLICY_FIRST:-0}
POLICY_INSTALLED=0

# install_policy_chart: the policy chart as release "policy" in namespace "policy", with
# test/e2e/values/policy.yaml. --take-ownership adopts the CRD run.sh applied under MESH=none.
install_policy_chart() {
  if [[ $POLICY_INSTALLED == 1 ]]; then return 0; fi
  quiet "$HELM" install policy "$POLICY_CHART" -n policy --create-namespace \
    -f "$HERE/values/policy.yaml" --take-ownership --wait
  POLICY_INSTALLED=1
  info "policy chart installed ($(basename "$POLICY_CHART"))"
}

uninstall_policy_chart() {
  if [[ $POLICY_FIRST == 1 || $POLICY_INSTALLED == 0 ]]; then return 0; fi
  quiet "$HELM" uninstall policy -n policy --wait
  "$KUBECTL" delete namespace policy --wait=false >/dev/null 2>&1 || true
  POLICY_INSTALLED=0
  info "policy chart uninstalled (its CRD is kept)"
}

# install_platform_exceptions: istio-system's posture-exceptions, from
# test/e2e/values/istio-system.yaml, rendered by posture itself before Istio is installed.
install_platform_exceptions() {
  "$KUBECTL" create namespace istio-system >/dev/null
  quiet "$HELM" install posture "$ROOT/charts/posture" -n istio-system \
    -f "$HERE/values/exceptions-only.yaml" -f "$HERE/values/istio-system.yaml" --wait
  info "posture-exceptions installed in istio-system (test/e2e/values/istio-system.yaml)"
}

# posture_first <namespace>: posture as the namespace's first release, rendering only an empty
# posture-exceptions (test/e2e/values/exceptions-only.yaml), so pods created before the
# scenario's posture values apply are admitted. install_posture upgrades it.
posture_first() {
  quiet "$HELM" install posture "$ROOT/charts/posture" -n "$1" \
    -f "$HERE/values/exceptions-only.yaml" --wait
}

# refused_pods <namespace>: the admission refusals there (FailedCreate events name the policy);
# a refused DaemonSet or ReplicaSet pod otherwise only shows up as a timeout.
refused_pods() {
  local events
  events=$("$KUBECTL" -n "$1" get events --field-selector reason=FailedCreate \
    -o custom-columns=OBJECT:.involvedObject.name,MESSAGE:.message --no-headers 2>/dev/null)
  if [[ -n $events ]]; then printf '\n--- pods refused in %s\n%s\n' "$1" "$events" >&2; fi
}

# admitted <message> <namespace> <pod>: the manifest on stdin is accepted and the pod becomes
# Ready.
admitted() {
  local message=$1 ns=$2 pod=$3 out
  if ! out=$("$KUBECTL" apply -f - 2>&1); then
    record FAIL "$message (refused: $out)"
  elif "$KUBECTL" -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null 2>&1; then
    record PASS "$message"
  else
    record FAIL "$message (admitted, but not Ready)"
  fi
}

# refused <message> <policy>: the manifest on stdin is refused, and the error names the policy.
refused() {
  local message=$1 policy=$2 out
  if out=$("$KUBECTL" apply -f - 2>&1); then
    record FAIL "$message (admitted)"
  elif [[ $out == *"$policy"* ]]; then
    record PASS "$message"
  else
    record FAIL "$message (refused, but not by $policy: $out)"
  fi
}

# shellcheck disable=SC2034 # read by run.sh
KEPT_SCENARIO=""

# dump_state: a short overview after a failed scenario. For details, rerun with E2E_KEEP=1 and
# inspect the namespaces it keeps (kubectl get networkpolicies -o yaml, and so on).
dump_state() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    printf '\n--- namespace %s\n' "$ns"
    "$KUBECTL" -n "$ns" get pods -o wide 2>&1 || true
    "$KUBECTL" -n "$ns" get networkpolicies 2>&1 || true
    refused_pods "$ns"
  done
  if [[ ${E2E_KEEP:-0} != 1 ]]; then
    printf '\n(rerun with E2E_KEEP=1 E2E_ARGS=<scenario> to keep these namespaces for inspection)\n'
  fi
}
