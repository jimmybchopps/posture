# shellcheck shell=bash
# examples/exceptions.yaml in "apps", against the pinned policy chart's baked-in policies: the
# posture-exceptions object is accepted by the CRD, and lets the workloads it names run despite
# the policies they break. Deliberately small: the policy chart's own e2e covers every policy,
# the controller warnings, kube-system, and failing closed in a namespace without posture.
#
#   node-agent  hostPath volume (disallow-host-path, restrict-volume-types)  excepted: runs
#   legacy      runs as root (require-run-as-non-root), matched by instance  excepted: runs
#   intruder    node-agent's spec under another name                         refused (by either
#                                                                            hostPath policy)
#
# Not mesh-specific (admission doesn't depend on the mesh), so it runs under every mesh. Under
# MESH=none it installs the policy chart and removes it in teardown; under a mesh the chart is
# already installed for the whole run (POLICY_FIRST), and both calls do nothing.

setup() {
  install_policy_chart
  namespace apps
  # The test pods' own service account (disallow-default-service-account).
  quiet "$KUBECTL" -n apps create serviceaccount test-pod
}

install() {
  # Succeeds only if the API server's CRD accepts posture-exceptions.
  install_posture apps exceptions.yaml
}

checks() { :; }   # no connection checks

# test_pod <name> <labels> <hostpath|root>: a bare Pod (agnhost porter, HTTP on 8080) that meets
# every policy the policy chart turns on by default (e2e enforces them all) except its one
# variant.
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
  serviceAccountName: test-pod
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: ${nonroot}
    runAsUser: ${user}
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      image: ${AGNHOST_IMAGE}
      args: [porter]
      env:
        - { name: SERVE_PORT_8080, value: ${name} }
      readinessProbe:
        tcpSocket: { port: 8080 }
        periodSeconds: 2
      livenessProbe:
        tcpSocket: { port: 8080 }
        periodSeconds: 10
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 64Mi }${mounts}${volumes}
YAML
}

# Here-strings, not pipes: admitted and refused must run in this shell so their results count.
extra() {
  admitted "[exceptions] excepted from disallow-host-path and restrict-volume-types: apps/node-agent runs" \
    apps node-agent <<<"$(test_pod node-agent "app.kubernetes.io/name: node-agent" hostpath)"
  admitted "[exceptions] excepted from require-run-as-non-root (by instance label): apps/legacy runs" \
    apps legacy <<<"$(test_pod legacy "app.kubernetes.io/name: legacy-app, app.kubernetes.io/instance: legacy" root)"
  refused "[exceptions] not excepted: apps/intruder is refused (disallow-host-path or restrict-volume-types)" \
    disallow-host-path restrict-volume-types <<<"$(test_pod intruder "app.kubernetes.io/name: intruder" hostpath)"
}

teardown() {
  uninstall_policy_chart
}
