# shellcheck shell=bash
# mtls.mode STRICT with api's 8081 excluded (see _mtls.sh).
# shellcheck source=test/e2e/scenarios/_mtls.sh
source "${HERE}/scenarios/_mtls.sh"

install() {
  install_posture apps mtls.yaml
}

checks() {
  expect deny plain/x api.apps:8080          # plaintext on a strict port
  expect allow plain/x api.apps:8081         # plaintext on the excluded port
  expect allow apps/web api.apps:8080        # mesh client, mTLS
  expect allow apps/web api.apps:8081        # mesh client on the excluded port, still mTLS
}
