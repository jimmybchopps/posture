# shellcheck shell=bash
# examples/minimal.yaml in "apps": default deny both ways, same-namespace traffic on any port,
# DNS (every check below resolves a Service name).

setup() {
  namespace apps
  namespace other
  workload apps a 8080 9090
  workload apps b 8080 9090
  workload other x 8080
}

install() {
  install_posture apps minimal.yaml
}

checks() {
  expect allow apps/a b.apps:8080
  expect allow apps/a b.apps:9090          # same namespace: any port
  expect allow apps/b a.apps:9090
  expect deny other/x b.apps:8080          # ingress from another namespace
  expect deny apps/a x.other:8080          # egress to another namespace
  expect deny apps/a "${EXT_IP}:443"       # egress out of the cluster
}
