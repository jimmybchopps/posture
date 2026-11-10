# shellcheck shell=bash
# examples/strict.yaml in "apps": no same-namespace allow, only web -> api on 8080, which needs
# both web's egress rule and api's ingress rule.

setup() {
  namespace apps
  namespace other
  workload apps web 8080 8081
  workload apps api 8080 8081
  workload other x 8080
}

install() {
  install_posture apps strict.yaml
}

checks() {
  expect allow apps/web api.apps:8080      # explicit pair, and DNS still works
  expect deny apps/web api.apps:8081       # port not in the rule
  expect deny apps/api web.apps:8080       # the reverse direction isn't allowed
  expect deny other/x api.apps:8080        # another namespace
}
