# Changelog

Newest first, one `## X.Y.Z` section per release. A version's section stays marked
`(unreleased)` until the release commit; the release workflow refuses a tag whose section
still is, or whose version doesn't match `charts/posture/Chart.yaml`.

## 0.1.0 (unreleased)

First release. Sets the security posture of the workloads in one namespace, from one set of
values, with no cluster-scoped objects and no CRDs.

- NetworkPolicies: default deny per direction, `allowSameNamespace`, `allowDNS`, and one
  object per target and peer, named `allow-<direction>-from-<source>-to-<destination>` and
  annotated with the values path it came from (`posture.dev/rule`).
- Rules are maps keyed by workload name, with numeric ports always required; peers by
  workload, namespace (`any` for every one), service account, or CIDR; predefined sources
  (`monitoring`, `ingress-gateway`) and destinations (`dns`, `kube-api`, `postgres`, ...),
  overridable field by field, plus custom ones.
- `enabled` on every rule, peer, reference, exclusion, exception, and profile: switched-off
  entries are validated but render nothing, and NOTES.txt lists them.
- Meshes: `none` and `istio` (ambient, L4). Under Istio: HBONE (15008) added to in-cluster
  NetworkPolicy rules, kubelet probes allowed, AuthorizationPolicies from the ingress rules
  (mesh identities by service account), and mTLS (`STRICT`, `PERMISSIVE`, or `inherit`) with
  per-port plaintext exclusions. A rule the mesh can't express fails the render; nothing is
  silently weakened.
- Admission-policy exceptions: `posture-exceptions` (`PolicyExceptions`,
  `policy.posture.dev/v1alpha1`), always rendered so the policies fail closed, with reasons
  and expiry dates. Tested against the policy chart 0.1.0.
- Profiles for Istio's own namespaces: `istio-system`, `istio-ingress`, and `istio-egress`,
  with `meshMember: false` for namespaces whose pods are the mesh itself.
- Egress to hostnames (`egress.allowedHosts`, Istio): a ServiceEntry per entry, routed
  through the egress waypoint, and one NetworkPolicy to the waypoint.
- Tested with Helm 3.14.4, 3.22.1, and 4.3.1, and end to end on k3d with Calico, with and
  without Istio 1.32.

Known limitations:

- Under Istio ambient, an egress port limit to a meshed pod in a namespace without posture
  isn't enforced (`deny prometheus/prometheus -> x.intruder:8081`, an accepted e2e failure)
  until the `boundary` integration.
- The gateway profiles (`istio-ingress`, `istio-egress`) and `egress.allowedHosts` are covered
  by unit tests only; their end-to-end tests come with `boundary`.
- Linkerd and Cilium aren't supported yet.
