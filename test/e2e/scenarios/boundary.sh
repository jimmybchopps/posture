# shellcheck shell=bash
# posture with the boundary chart (the pinned release, BOUNDARY_CHART), under the policy chart
# with every default-on policy enforced. The values are in test/e2e/values/boundary/.
#
#   ingress-gateway  posture: the istio-ingress profile; boundary's https gateway
#   egress-gateway   posture: the istio-egress profile; boundary's default egress waypoint,
#                    which allows allowed-tls.e2e.test only
#   shop    meshed; runs api, reached through https as api.shop.e2e.test. posture: the
#           ingress-gateway source on 8080
#   apps    meshed; runs x. posture asks for allowed-tls and denied-tls (egress.allowedHosts)
#   other   meshed; runs x. posture asks for no hosts
#   client  outside the mesh; runs x, a client from outside the cluster. posture: egress to the
#           ingress gateways only
#
# Both external names resolve to the TLS external host (EXT_TLS, external_dns). Istio only:
# egress.allowedHosts and the gateway profiles need it.
# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

INGRESS_NAMESPACE=ingress-gateway
EGRESS_NAMESPACE=egress-gateway
BOUNDARY_VALUES=test/e2e/values/boundary

setup() {
  # The gateway namespaces first, each with its posture profile, so boundary's gateway and
  # waypoint pods are admitted (as boundary's README orders the install).
  namespace "$INGRESS_NAMESPACE"
  namespace "$EGRESS_NAMESPACE"
  install_posture "$INGRESS_NAMESPACE" "$BOUNDARY_VALUES/ingress-gateway.yaml"
  install_posture "$EGRESS_NAMESPACE" "$BOUNDARY_VALUES/egress-gateway.yaml"
  make_cert apps "*.shop.e2e.test"
  tls_secret "$INGRESS_NAMESPACE" apps-tls apps
  install_boundary

  namespace shop
  namespace apps
  namespace other
  MESHED=0 namespace client
  "$KUBECTL" label namespace shop ingress.boundary.posture.dev/https=true >/dev/null
  workload shop api 8080
  workload apps x 8080
  workload other x 8080
  workload client x 8080
  httproute shop api api.shop.e2e.test
}

install() {
  install_posture shop "$BOUNDARY_VALUES/shop.yaml"
  install_posture apps "$BOUNDARY_VALUES/apps.yaml"
  install_posture other "$BOUNDARY_VALUES/other.yaml"
  install_posture client "$BOUNDARY_VALUES/client.yaml" --set mesh=none
}

checks() {
  # Egress through boundary's waypoint
  expect allow apps/x https://allowed-tls.e2e.test:443     # asked for, and on boundary's list
  expect deny apps/x https://denied-tls.e2e.test:443       # asked for, not on boundary's list
  expect deny other/x https://allowed-tls.e2e.test:443     # on boundary's list, not asked for
  expect deny apps/x "https://${EXT_TLS}:443"              # the direct path, skipping the waypoint

  # Ingress: only through the gateway
  expect deny client/x api.shop:8080                       # straight to the backend
}

extra() {
  # The waypoint's access log shows where each request went: allowed-tls through it, and
  # denied-tls refused by it (not by a NetworkPolicy on the way).
  check "[boundary] egress: apps' request for allowed-tls went through the default waypoint" \
    gateway_logs_have "$EGRESS_NAMESPACE" default allowed-tls.e2e.test
  check "[boundary] egress: apps' request for denied-tls reached the default waypoint, which refused it" \
    gateway_logs_have "$EGRESS_NAMESPACE" default denied-tls.e2e.test

  # Ingress through the istio-ingress profile and shop's ingress-gateway source.
  check "[boundary] ingress: client reaches https://api.shop.e2e.test through the https gateway (200)" \
    status_is 200 client/x https api.shop.e2e.test 443 https://api.shop.e2e.test/

  # Admission: Istio's own pods run with only the profiles' exceptions.
  local entry ns gw component
  for entry in "$INGRESS_NAMESPACE https ingress-gateway" "$EGRESS_NAMESPACE default egress-waypoint"; do
    read -r ns gw component <<<"$entry"
    check "[boundary] admission: ${ns}/${gw}'s pods are admitted and its Deployment is available" \
      gateway_available "$ns" "$gw"
    check "[boundary] admission: ${ns}'s posture-exceptions holds exactly the profile's two exceptions" \
      profile_exceptions_are "$ns" "disallow-mesh-opt-out=${component};require-probes=${component};"
  done
  for ns in istio-system "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    check "[boundary] admission: no pod in ${ns} was refused" no_refused_pods "$ns"
  done
}

teardown() {
  uninstall_boundary
}

# ---------------------------------------------------------------------------------------------
# Helpers (boundary's own harness has the same ones; posture never reads boundary's files)

# install_boundary: the pinned package as release "boundary" in istio-system, then waits until
# every gateway and waypoint is programmed and its Deployment is available.
install_boundary() {
  if ! quiet "$HELM" install boundary "$BOUNDARY_CHART" -n istio-system \
    -f "$ROOT/$BOUNDARY_VALUES/boundary.yaml" --wait; then
    refused_pods "$INGRESS_NAMESPACE"
    refused_pods "$EGRESS_NAMESPACE"
    die "boundary didn't install"
  fi
  local ns gateway
  for ns in "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    for gateway in $("$KUBECTL" -n "$ns" get gateways -o jsonpath='{.items[*].metadata.name}'); do
      quiet "$KUBECTL" -n "$ns" wait --for=condition=Programmed "gateway/$gateway" --timeout=180s ||
        { refused_pods "$ns"; die "gateway ${ns}/${gateway} isn't programmed"; }
      retry gateway_deployment "$ns" "$gateway" ||
        { refused_pods "$ns"; die "Istio generated no Deployment for gateway ${ns}/${gateway}"; }
      quiet "$KUBECTL" -n "$ns" rollout status "$(gateway_deployment "$ns" "$gateway")" --timeout=180s ||
        { refused_pods "$ns"; die "gateway ${ns}/${gateway} isn't available"; }
    done
  done
  info "boundary installed ($(basename "$BOUNDARY_CHART")); its gateways and waypoints are ready"
}

# uninstall_boundary: waits until the Deployments Istio generated for its gateways are gone,
# before cleanup_namespaces removes the gateway namespaces' posture.
uninstall_boundary() {
  local ns
  "$HELM" uninstall boundary -n istio-system --wait >/dev/null 2>&1 || true
  for ns in "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    "$KUBECTL" -n "$ns" wait --for=delete deployment \
      -l gateway.networking.k8s.io/gateway-name --timeout=120s >/dev/null 2>&1 || true
  done
  info "boundary uninstalled"
}

# retry <command...>: runs it until it succeeds, for up to about 30 seconds.
retry() {
  local _attempt
  for _attempt in $(seq 1 15); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# gateway_deployment <namespace> <gateway>: the Deployment Istio generated for it
# (<gateway>-istio for an ingress gateway, <gateway> for a waypoint); fails if there's none.
gateway_deployment() {
  local d
  d=$("$KUBECTL" -n "$1" get deployment -l "gateway.networking.k8s.io/gateway-name=$2" -o name 2>/dev/null)
  [[ -n $d ]] && printf '%s\n' "$d"
}

gateway_available() {
  local d
  d=$(gateway_deployment "$1" "$2") || return 1
  "$KUBECTL" -n "$1" wait --for=condition=Available "$d" --timeout=10s
}

# gateway_logs_have <namespace> <gateway> <text>: one of its pods logged a line containing
# text. Each pod's whole log is read by name: with a selector, kubectl logs shows only the last
# 10 lines per pod.
gateway_logs_have() {
  local ns=$1 pod logs
  for pod in $("$KUBECTL" -n "$ns" get pods \
    -l "gateway.networking.k8s.io/gateway-name=$2" -o name 2>/dev/null); do
    logs=$("$KUBECTL" -n "$ns" logs "$pod" -c istio-proxy 2>/dev/null) || continue
    [[ $logs == *"$3"* ]] && return 0
  done
  return 1
}

# status_is <want> <ns>/<workload> <gateway> <host> <port> <curl args...>: curl from the
# workload's client container to <gateway>'s Service, with <host> as SNI and Host
# (--connect-to); the response status is <want>.
status_is() {
  local want=$1 ns=${2%%/*} name=${2#*/} gateway=$3 host=$4 port=$5 got
  shift 5
  got=$("$KUBECTL" -n "$ns" exec "deploy/${name}" -c client -- curl -sS -k -m 5 \
    --connect-to "${host}:${port}:${gateway}-istio.${INGRESS_NAMESPACE}.svc.cluster.local:${port}" \
    -o /dev/null -w '%{http_code}' "$@" 2>/dev/null) || true
  [[ $got == "$want" ]]
}

# profile_exceptions_are <namespace> <want>: the namespace's posture-exceptions, as
# "<policy>=<component label>;" per exception, is exactly <want>.
profile_exceptions_are() {
  local got
  got=$("$KUBECTL" -n "$1" get policyexceptions posture-exceptions \
    -o jsonpath='{range .spec.exceptions[*]}{.policy.name}={range .workloads[*]}{.matchLabels.app\.kubernetes\.io/component}{end};{end}') || return 1
  [[ $got == "$2" ]]
}

# no_refused_pods <namespace>: no pod there was refused at admission (FailedCreate events).
no_refused_pods() {
  [[ -z $("$KUBECTL" -n "$1" get events --field-selector reason=FailedCreate -o name 2>/dev/null) ]]
}

# httproute <namespace> <service> <hostname>: an HTTPRoute for the https gateway, sending
# <hostname> to <service>:8080.
httproute() {
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: $2, namespace: $1 }
spec:
  parentRefs:
    - { name: https, namespace: ${INGRESS_NAMESPACE} }
  hostnames: [$3]
  rules:
    - backendRefs:
        - { name: $2, port: 8080 }
EOF
}
