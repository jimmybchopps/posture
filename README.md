# posture

A Helm chart that sets the security posture of the workloads in **one namespace**: network
policies, mesh authorization policies, mTLS settings, and admission-policy exceptions, all
from one short set of values.

You install it once per namespace, next to whatever else runs there. It renders only
namespaced objects and installs no CRDs, so someone with namespace-level permissions can
install it.

- **Meshes:** none and Istio (ambient mode, L4) today. Linkerd and Cilium come next (see
  [docs/PLAN.md](docs/PLAN.md)).
- **Releases:** [CHANGELOG.md](CHANGELOG.md).

Companion charts: [`policy`](https://github.com/jimmybchopps/policy) (the cluster's admission
policies) and [`boundary`](https://github.com/jimmybchopps/boundary) (ingress and egress
gateways, the cluster-wide egress limit, and mesh-wide settings). posture never references
either. The charts share a few conventions: namespace names, the gateway pod labels, and the
`allowedHosts` shape. posture is useful on its own, without either of them.

## What you write, and what you get

Values for a `grafana` namespace: Grafana is reached through the ingress gateway, scraped by
Prometheus, and talks to Postgres and SSO outside the cluster
([examples/grafana.yaml](examples/grafana.yaml)):

```yaml
ingress:
  grafana:                      # pods labeled app.kubernetes.io/name=grafana
    sources:
      ingress-gateway: [3000]   # every pod in namespace ingress-gateway
      monitoring: [3000]        # prometheus in namespace prometheus

egress:
  grafana:
    destinations:
      postgres: {}              # the private ranges, port 5432
      sso: {}                   # the private ranges, ports 443 and 8443
```

With `mesh: none` this renders:

| Kind | Name |
|---|---|
| NetworkPolicy | `deny-all-ingress`, `deny-all-egress` |
| NetworkPolicy | `allow-ingress-from-ingress-gateway-to-grafana` |
| NetworkPolicy | `allow-ingress-from-monitoring-to-grafana` |
| NetworkPolicy | `allow-egress-from-grafana-to-postgres` |
| NetworkPolicy | `allow-egress-from-grafana-to-sso` |
| NetworkPolicy | `allow-egress-from-all-to-dns`, `allow-same-namespace` |
| PolicyExceptions | `posture-exceptions` (empty) |

With `mesh: istio`, the same values also render an AuthorizationPolicy per ingress rule, plus
a namespace-wide allow-nothing policy and a STRICT mTLS PeerAuthentication. Every
NetworkPolicy rule to an in-cluster peer also opens HBONE (15008).

Every object is named for what it allows (`allow-<direction>-from-<source>-to-<destination>`)
and carries the annotation `posture.dev/rule` with the values path it came from. Adding or
removing a rule never renames another object.

## Install

From a release, with the chart archive checked against the release's `SHA256SUMS`:

```sh
v=0.3.0
base=https://github.com/jimmybchopps/posture/releases/download/v$v
curl -fsSLO "$base/posture-$v.tgz" && curl -fsSLO "$base/SHA256SUMS"
sha256sum -c SHA256SUMS
helm install posture "posture-$v.tgz" -n <namespace> -f values.yaml
```

Or from a checkout: `helm install posture ./charts/posture -n <namespace> -f values.yaml`.

- Install one release per namespace, named `posture`.
- Under the `policy` chart, install posture **before anything else** in the namespace. The
  policies refuse every pod in a namespace without `posture-exceptions`.
- Every value is checked by the chart's JSON schema and its model. If the selected mesh can't
  express a rule, the install fails, naming the rule and the reason; a rule is never dropped
  or loosened.
- Nothing depends on what's in the cluster: `helm template` renders exactly what
  `helm install` applies.

### Requirements

- Helm 3.14+ or Helm 4.
- A CNI that enforces NetworkPolicy (Calico and Cilium are tested; k3s's default flannel
  doesn't enforce it).
- The `PolicyExceptions` CRD, which the `policy` chart installs. Without it, set
  `policyExceptions.enabled: false`.
- For `mesh: istio`: Istio in ambient mode, installed and healthy. Tested with Istio 1.32.

## Values at a glance

The full contract, with every field and rule, is in [CLAUDE.md](CLAUDE.md) ("Values contract"
and the rendering rules). The essentials:

- **Rules are maps keyed by workload name.** `ingress.<workload>` lists who may reach it
  (`from` for workloads, `sources` for predefined or custom sources). `egress.<workload>`
  lists where it may go (`to`, `destinations`). The key `any` means every pod.
- **Ports are always required and always numeric.** There's no "all ports" form and no named
  ports. A port is `8080`, `{ port: 53, protocol: UDP }`, or `{ port: 32000, endPort: 32768 }`.
- **Peers:** a workload in this namespace or another (`namespace: X`, or `namespace: any`), its
  service account for mesh identity (`serviceAccount`), or addresses outside the cluster
  (`cidrs`).
- **Predefined sources and destinations** cover common cases: `monitoring`,
  `ingress-gateway`, `dns`, `kube-api`, `postgres`, `redis`, `https`, `sso`, `storage`, `ldap`,
  `smtp`, `ntp`, `syslog`, and `egress-gateway`. Override any field (a namespace, addresses,
  ports) or add your own under `sources` and `destinations`.
- **Everything has `enabled`** (default true). A disabled entry is still validated but renders
  nothing, and NOTES.txt lists it.
- **mTLS** (`mtls.mode`: `STRICT`, `PERMISSIVE`, or `inherit`), with per-port plaintext
  exclusions per workload under STRICT.
- **Admission-policy exceptions** (`exceptions.<workload>.policies.<policy>`), each with a
  reason and an optional expiry date. They're rendered into `posture-exceptions`, which the
  `policy` chart reads.
- **Egress to host names** (`egress.allowedHosts`, Istio): hosts outside the cluster this
  namespace may reach through the egress waypoint. `boundary`'s list at the waypoint is the
  cluster-wide limit, so a namespace can ask for a host but never grant itself one.

Complete values files, which are also the test fixtures, are in [examples/](examples/):

| File | What it shows |
|---|---|
| `minimal.yaml` | the defaults: default deny, same-namespace traffic, DNS |
| `grafana.yaml` | predefined sources in, predefined destinations out |
| `prometheus.yaml` | scraping listed metrics ports in every namespace |
| `strict.yaml` | no blanket same-namespace allow: pods reach each other only where a rule says so |
| `istio.yaml` | `grafana.yaml` under Istio ambient |
| `identity.yaml` | peers matched by service account (mesh identity) |
| `mtls.yaml` | STRICT mTLS with a plaintext exclusion |
| `exceptions.yaml` | admission-policy exceptions, with reasons and expiry |
| `allowed-hosts.yaml` | egress to host names through the egress waypoint |
| `profile-istio-*.yaml` | the built-in profiles below |

## Profiles

A profile is a layer of values, built into the chart, that makes a known component's
namespace work out of the box: its network rules, its policy exceptions (each with a reason),
and its mesh settings. You turn it on and supply only what your site knows. Your own values
are layered on top and always win. Anything a profile adds can be switched off with
`enabled: false`.

| Profile | For the namespace | Settings |
|---|---|---|
| `istio-system` | Istio's control plane (istiod, ztunnel) | `apiServerCidrs` (required): where the API server calls istiod's webhooks from |
| `istio-ingress` | `ingress-gateway`, boundary's ingress gateways | `ports` (default 443, 80), `clientCidrs` (default the private ranges) |
| `istio-egress` | `egress-gateway`, boundary's egress waypoint | `ports` (default 443, 80) |

```yaml
# values for istio-system
profiles:
  istio-system:
    settings:
      apiServerCidrs: [10.0.0.0/24]
```

A profile's exceptions cover every policy the `policy` chart turns on by default, including
the ones that only audit, wherever the component fails it and its own chart has no setting to
fix it. So a site that enforces all of them isn't caught out. Settings a site makes when it
installs the component aren't excepted: install Istio with its images pinned by digest and a
memory limit for istiod and ztunnel.

Profiles for applications (Prometheus, Grafana, ...) aren't built in: they're plain values
files, layered with `-f`.

## Install order with Istio, `policy`, and `boundary`

On a cluster with every companion chart, as the end-to-end tests run it:

1. The Gateway API CRDs (standard channel), if you use `boundary`.
2. The `policy` chart. From here on, pods in a namespace without `posture-exceptions` are
   refused.
3. posture in `istio-system`, with the `istio-system` profile and `mesh: none` (Istio's CRDs
   don't exist yet).
4. Istio (ambient), with istio-cni in `kube-system`.
5. posture in `istio-system` upgraded to `mesh: istio`.
6. The gateway namespaces, enrolled in the mesh, each with posture and its profile
   (`istio-ingress`, `istio-egress`), then `boundary`.
7. Each application namespace: posture first, then its workloads.

Under ambient, a port limit on egress to another meshed pod is enforced by the destination
namespace's own posture, not the source's. Between meshed pods, NetworkPolicy sees only
HBONE on 15008, never the original port. Every namespace needs posture under the `policy`
chart, so the destination always has a posture of its own to enforce it.

## Development

Tools are pinned in the [Makefile](Makefile) and installed into `.bin/`; nothing is installed
globally.

```sh
make tools            # helm, helm-unittest, kubeconform
make test             # lint, unit tests, kubeconform on every example, release-script cases
make test-all-helm    # make test under Helm 3.14, the latest 3.x, and 4
make e2e MESH=none    # k3d + Calico end-to-end tests; needs Docker
make e2e MESH=istio   # the same with Istio ambient, the policy chart enforced, and boundary
```

The end-to-end tests check, for every rule, that the allowed path connects and a denied path
doesn't. Each check first runs before posture is installed, so a deny can't pass for the
wrong reason. Under Istio they run the pinned `policy` release with every default-on policy
enforced, and the pinned `boundary` release.

The build plan and the decisions behind it are in [docs/PLAN.md](docs/PLAN.md).
[CLAUDE.md](CLAUDE.md) is the full specification: principles, values contract, rendering
rules, and naming.

## License

[Apache License 2.0](LICENSE).
