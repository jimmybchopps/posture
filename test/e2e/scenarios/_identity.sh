# shellcheck shell=bash
# Shared by the identity scenarios (Istio only): examples/identity.yaml in "apps", where api
# accepts web on 8080 only from the "web" service account. fake-web copies web's labels but runs
# as another service account, so the NetworkPolicies (labels) let it through and only the
# AuthorizationPolicies (mesh identity) can refuse it. Each scenario installs the same values
# with one layer or the other turned off, to show each layer blocks on its own.
#
# Not a scenario itself (the leading underscore keeps it out of run.sh's default list).

# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

setup() {
  namespace apps
  namespace other
  workload apps api 8080 8081
  workload apps web 8080
  LABEL=web SA=impostor workload apps fake-web 8080
  workload other x 8080
}
