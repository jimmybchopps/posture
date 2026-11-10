# shellcheck shell=bash
# Shared by the mTLS scenarios (Istio only): examples/mtls.yaml in "apps", where api accepts web
# (in the mesh, so mTLS) and x from namespace "plain" (outside the mesh, so plaintext) on 8080
# and 8081, with mtls.exclusions.api: [8081]. Both clients pass the NetworkPolicies on both
# ports, so whether x connects is decided by mTLS and the plaintext authorization policy.
#
# Not a scenario itself (the leading underscore keeps it out of run.sh's default list).

# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

setup() {
  namespace apps
  MESHED=0 namespace plain
  workload apps api 8080 8081
  workload apps web 8080
  workload plain x 8080
}
