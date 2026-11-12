# shellcheck shell=bash
# examples/exceptions.yaml in "apps", against the pinned policy chart's baked-in policies: the
# posture-exceptions object is accepted by the CRD, and lets the workloads it names run despite
# the policies they break. Deliberately small: the policy chart's own e2e covers every policy,
# the controller warnings, kube-system, and failing closed in a namespace without posture.
#
#   node-agent  hostPath volume (disallow-host-path, restrict-volume-types)  excepted: runs
#   legacy      runs as root (require-run-as-non-root), matched by instance  excepted: runs
#   intruder    node-agent's spec under another name                         refused
#
# Not mesh-specific (admission doesn't depend on the mesh), so it runs under every mesh. Under
# MESH=none it installs the policy chart and removes it in teardown; under a mesh the chart is
# already installed for the whole run (POLICY_FIRST), and both calls do nothing.

setup() {
  install_policy_chart
  namespace apps
}

install() {
  # Succeeds only if the API server's CRD accepts posture-exceptions.
  install_posture apps exceptions.yaml
}

checks() { :; }   # no connection checks

# test_pod <name> <labels> <hostpath|root>: a bare Pod (agnhost pause) that meets every
# baked-in policy except its one variant.
test_pod() {
  local name=$1 labels=$2 variant=$3 user=65532 nonroot=true volumes="" mounts=""
  case $variant in
    hostpath)
      volumes="
  volumes:
    - { name: proc, hostPath: { path: /proc, type: Directory } }"
      mounts="
      volumeMounts:
        - { name: proc, mountPath: /host/proc, readOnly: true }" ;;
    root) user=0 nonroot=false ;;
    *) die "test_pod: unknown variant $variant" ;;
  esac
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: apps
  labels: { ${labels} }
spec:
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: ${nonroot}
    runAsUser: ${user}
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      image: ${AGNHOST_IMAGE}
      args: [pause]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }${mounts}${volumes}
YAML
}

extra() {
  test_pod node-agent "app.kubernetes.io/name: node-agent" hostpath \
    | admitted "[exceptions] excepted from disallow-host-path and restrict-volume-types: apps/node-agent runs" apps node-agent
  test_pod legacy "app.kubernetes.io/instance: legacy" root \
    | admitted "[exceptions] excepted from require-run-as-non-root (by instance label): apps/legacy runs" apps legacy
  test_pod intruder "app.kubernetes.io/name: intruder" hostpath \
    | refused "[exceptions] not excepted: apps/intruder is refused by disallow-host-path" disallow-host-path
}

teardown() {
  uninstall_policy_chart
}
