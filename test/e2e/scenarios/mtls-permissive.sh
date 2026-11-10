# shellcheck shell=bash
# mtls.mode PERMISSIVE for the whole namespace, no exclusions (see _mtls.sh): every port also
# accepts plaintext, and the NetworkPolicies decide which plaintext peers get in.
# shellcheck source=test/e2e/scenarios/_mtls.sh
source "${HERE}/scenarios/_mtls.sh"

install() {
  install_posture apps mtls.yaml --set mtls.mode=PERMISSIVE --set-json 'mtls.exclusions={}'
}

checks() {
  expect allow plain/x api.apps:8080         # plaintext, PERMISSIVE
  expect allow plain/x api.apps:8081         # plaintext, PERMISSIVE
  expect allow apps/web api.apps:8080        # mesh client, mTLS
}
