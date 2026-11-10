# shellcheck shell=bash
# NetworkPolicies alone: authorization off (see _identity.sh). The deny below is the
# NetworkPolicies' doing; the allows marked "NetworkPolicy alone" show what only the
# authorization layer can refuse.
# shellcheck source=test/e2e/scenarios/_identity.sh
source "${HERE}/scenarios/_identity.sh"

install() {
  install_posture apps identity.yaml --set authorization.enabled=false
}

checks() {
  expect allow apps/web api.apps:8080        # the pair in the rule
  expect deny other/x api.apps:8080          # another namespace: no NetworkPolicy admits it
  expect allow apps/fake-web api.apps:8080   # NetworkPolicy alone: labels match, identity unchecked
  expect allow apps/web api.apps:8081        # NetworkPolicy alone: it only sees HBONE on 15008
}
