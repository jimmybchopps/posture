# shellcheck shell=bash
# Both layers on (see _identity.sh).
# shellcheck source=test/e2e/scenarios/_identity.sh
source "${HERE}/scenarios/_identity.sh"

install() {
  install_posture apps identity.yaml
}

checks() {
  expect allow apps/web api.apps:8080        # right identity, listed port
  expect deny apps/fake-web api.apps:8080    # right labels, wrong service account
  expect deny apps/web api.apps:8081         # port not in the rule
  expect deny other/x api.apps:8080          # another namespace
}
