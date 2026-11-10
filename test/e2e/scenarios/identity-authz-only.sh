# shellcheck shell=bash
# AuthorizationPolicies alone: both NetworkPolicy directions off (see _identity.sh). Every deny
# below is the mesh's doing.
# shellcheck source=test/e2e/scenarios/_identity.sh
source "${HERE}/scenarios/_identity.sh"

install() {
  install_posture apps identity.yaml --set networkPolicy.ingress=false --set networkPolicy.egress=false
}

checks() {
  expect allow apps/web api.apps:8080        # the principal and port in the rule
  expect deny apps/fake-web api.apps:8080    # wrong principal
  expect deny apps/web api.apps:8081         # port not in the rule
  expect deny other/x api.apps:8080          # no rule admits its identity
}
