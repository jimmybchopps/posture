# shellcheck shell=bash
# examples/grafana.yaml in "grafana" (examples/istio.yaml under MESH=istio) and
# examples/prometheus.yaml in "prometheus": the ingress gateway (namespace ingress-gateway, the
# ingress-gateway preset's default) and Prometheus into Grafana, Grafana out to
# postgres and sso on the external host, Prometheus scraping other namespaces.

setup() {
  namespace grafana
  namespace prometheus
  namespace ingress-gateway
  namespace intruder
  workload grafana grafana 3000 3001
  workload grafana renderer 8081
  workload prometheus prometheus 9090
  workload prometheus other 9090
  workload ingress-gateway envoy 8443
  workload intruder x 9100 8081
}

install() {
  if [[ $MESH == istio ]]; then
    install_posture grafana istio.yaml
  else
    install_posture grafana grafana.yaml
  fi
  install_posture prometheus prometheus.yaml
}

checks() {
  # Into grafana
  expect allow ingress-gateway/envoy grafana.grafana:3000    # ingress-gateway source
  expect deny ingress-gateway/envoy grafana.grafana:3001     # port not in the rule
  expect allow prometheus/prometheus grafana.grafana:3000    # scrape: both releases allow it
  expect deny prometheus/other grafana.grafana:3000          # wrong workload in prometheus
  expect deny intruder/x grafana.grafana:3000                # not in any rule
  expect allow grafana/renderer grafana.grafana:3001         # same namespace, any port

  # Out of grafana
  expect allow grafana/grafana "${EXT_IP}:5432"              # postgres preset (private ranges)
  expect allow grafana/grafana "${EXT_IP}:443"               # sso preset
  expect allow grafana/grafana "${EXT_IP}:8443"              # sso preset
  expect deny grafana/grafana "${EXT_IP}:8080"               # no destination lists 8080
  expect deny grafana/renderer "${EXT_IP}:5432"              # the rule is for grafana only
  expect deny grafana/grafana x.intruder:9100                # default-deny egress

  # Prometheus scraping a namespace without posture
  expect allow prometheus/prometheus x.intruder:9100         # listed metrics port
  expect deny prometheus/prometheus x.intruder:8081          # not a listed port
  expect deny prometheus/other x.intruder:9100               # the rule is for prometheus only
}

# Istio ambient: kubelet probes reach pods only through allow-ingress-from-ambient-probes-to-all
# (they arrive from 169.254.7.127). Restart grafana under the policy; its readiness probe must
# pass. The meshed checks above already cover 15008: the scrape only connects because 15008 is
# allowed, and the intruder is meshed too, so its HBONE to 15008 is what gets denied.
extra() {
  [[ $MESH == istio ]] || return 0
  "$KUBECTL" -n grafana rollout restart deployment/grafana >/dev/null
  if "$KUBECTL" -n grafana rollout status deployment/grafana --timeout=90s >/dev/null 2>&1; then
    record PASS "[policy] grafana becomes Ready after a restart (ambient probes allowed)"
  else
    record FAIL "[policy] grafana becomes Ready after a restart (ambient probes allowed)"
  fi
}
