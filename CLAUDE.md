# posture: context for Claude Code

`posture` is a Helm chart that sets the security posture of the workloads in **one namespace**:
network policies, authorization policies, mTLS settings, and admission-policy exceptions. It
works with Istio (ambient mode, L4 only), Linkerd, Cilium, or no mesh, from the same values.

It is installed once per namespace, alongside whatever charts run there. Cluster-wide pieces
(ingress and egress gateways, approved egress hostnames, mesh-wide resources) belong to a
separate chart, `boundary`, which this chart never references.

The build order is in `docs/PLAN.md`. Work through it phase by phase.

## Principles (don't break these)

- **Namespace-scoped only.** Never render a cluster-scoped object, never install CRDs.
  Someone with only namespaced permissions must be able to install the chart.
- **Ports are always required, always numeric.** Every rule lists the ports it opens; there is
  no "all ports" form and no named ports. Map keys name workloads; ports are numbers.
- **Short to write, familiar to read.** Rules are maps keyed by workload name; ports look
  like NetworkPolicy ports. Users shouldn't need to write label selectors or
  service-account references by hand for the common cases.
- **Maps, not lists, wherever a user might override.** Helm merges maps across values files
  and replaces lists wholesale. `ingress`, `egress`, `from`, `to`, `sources`, `destinations`,
  `mtls.exclusions`, and `exceptions` are all maps. Lists are only used for ports, CIDRs, and
  references to predefined destinations.
- **One model, many renderers.** Values are normalized once (`templates/_model.tpl`) into an
  internal model; every output (NetworkPolicy, Istio, Linkerd, Cilium, exceptions) renders
  from the model, never from raw values.
- **Never silently weaker.** If the selected mesh can't express something the values ask for,
  call `fail` with a message naming the rule and the reason. Never drop or loosen a rule.
- **Values decide, not the cluster.** No `lookup`, no `.Capabilities` checks to choose what to
  render. `helm template` must produce exactly what `helm install` applies. The one input from
  outside the values is the render date, used only by `exceptions.*.policies.*.expires`, and
  it can only remove an exception, never add one.
- **Stable, descriptive names.** Every object is named `allow-<direction>-from-<source>-to-<destination>`
  from map keys (see "Naming"), so names say what they allow and adding or removing one rule
  never renames another object.
- **Every generated object says why it exists**: annotation `posture.dev/rule` with the key
  path it came from (`ingress.grafana`, `allowDNS`, `networkPolicy.ingress`, ...).
- **No Neutron Star vocabulary.** The words "bundle" and "package" never appear in the chart.
  Neutron Star fills these values from its plan, but the chart must be useful on its own.

## Values contract

```yaml
mesh: none                      # none | istio | linkerd | cilium   (istio first; others later)
trustDomain: cluster.local      # used to build mesh identities

networkPolicy: { ingress: true, egress: true } # false for a direction = no NetworkPolicies
                                               # for it at all (troubleshooting only)
authorization: { enabled: true } # mesh authorization policies from the ingress rules; used
                                 # when mesh isn't none; false = none (troubleshooting only)
mtls:                           # used when mesh isn't none
  mode: STRICT                  # STRICT | PERMISSIVE | inherit (render nothing); never DISABLE
  exclusions:                   # workload in this namespace -> ports that also accept plaintext
    grafana: [9090]             # STRICT only; or { selector, ports }; "any" isn't accepted
allowSameNamespace: true        # all traffic between pods in this namespace
allowDNS: true                  # egress from every pod to the "dns" destination

policyExceptions: { enabled: true } # render posture-exceptions (even empty); false on clusters
                                    # without the PolicyExceptions CRD (then exceptions fail)
exceptions:                     # admission-policy exceptions; independent of mesh
  prometheus:                   # workload in this namespace, matched by label
    selector: name              # optional
    policies:
      disallow-host-path:       # policy name
        kind: ValidatingAdmissionPolicy   # or MutatingAdmissionPolicy
        reason: "node exporter reads /proc"   # optional
        expires: 2027-03-31     # optional; left out once past (applied at render)
        enabled: true           # optional, default true

# Define first: overrides of predefined sources and destinations, plus custom ones.
sources:
  monitoring: { namespace: observability }   # override: namespace only, workload stays prometheus
  backup-agent:                 # custom, inside the cluster: any name not already predefined
    namespace: backup
    workload: velero
    serviceAccount: velero
  office-vpn:                   # custom, outside the cluster
    cidrs: [10.50.0.0/16, { cidr: 10.60.0.0/16, except: [10.60.1.0/24] }]

destinations:
  postgres: { cidrs: [10.20.5.0/24] }   # override: address only, ports stay 5432
  storage:  { ports: [2049] }           # override: ports only, addresses stay the private ranges
  license-server:               # custom, outside the cluster
    cidrs: [10.30.0.15/32]
    ports: [27000, { port: 27001, protocol: UDP }]
  vault:                        # custom, inside the cluster
    namespace: vault
    workload: vault
    ports: [8200]

# Then use them.
ingress:
  grafana:                      # target: pods in this namespace with that label; "any" = every pod
    selector: name              # optional: name | component | instance | app (default name)
    from:
      keycloak:                 # a workload; "any" = every pod (in the namespace below)
        selector: instance      # optional, overrides the rule's selector for this entry
        namespace: keycloak     # omitted = this namespace; "any" = every namespace
        serviceAccount: keycloak   # optional; used by the authorization phase
        ports: [3000]           # required
    sources:                    # predefined or custom sources; value = ports on this workload (required)
      monitoring: [3000]
      ingress-gateway: [3000]
      backup-agent: [3000]
      office-vpn: [3000]

  any:                          # every pod in this namespace...
    from:
      any:                      # ...accepts traffic from every pod in "tooling"
        namespace: tooling
        ports: [8080]

egress:
  grafana:                      # source: pods in this namespace; "any" = every pod
    to:
      keycloak:
        namespace: keycloak
        ports: [8080]
    destinations: [postgres, sso, license-server, vault]   # predefined or custom; ports come from their definitions

  any:                          # every pod in this namespace...
    destinations: [https]       # ...may reach HTTPS on the private ranges
```

Order in a values file doesn't affect rendering, but `values.yaml`, the examples, and the docs
always put `sources` and `destinations` before `ingress` and `egress`, so readers see a name
defined before it's used.

A namespace running Prometheus shows the other common use of `any`, reaching every pod in
every namespace, on the metrics ports listed:

```yaml
# values for the "prometheus" namespace
egress:
  prometheus:
    to:
      any:
        namespace: any          # every namespace
        ports: [8080, 9090, 9100, { port: 9400, endPort: 9499 }]
```

The objects rendered from these examples include `allow-ingress-from-all-in-tooling-to-all`,
`allow-egress-from-all-to-https`, `allow-ingress-from-backup-agent-to-grafana`,
`allow-ingress-from-office-vpn-to-grafana`,
`allow-egress-from-grafana-to-license-server`, and `allow-egress-from-prometheus-to-all-namespaces`.

### Ports

A non-empty list, required on every `from`/`to` entry, every `sources` reference, and every
destination definition. Each item is a number (`9090`) or a port object with a numeric
`port` (`{ port: 53, protocol: UDP }`, `{ port: 32000, endPort: 32768 }`). `protocol` defaults
to TCP. Port names (`http`) are rejected by the schema: every output, including Istio's
authorization and mTLS resources, needs numbers, and this keeps all layers in agreement.

The only objects not limited to listed ports are the fixed ones the user opts into:
`allowSameNamespace` (all traffic within the namespace) and the defaults below.

### Selectors

`selector` picks which label a workload name is matched against:

| Value | Label |
|---|---|
| `name` (default) | `app.kubernetes.io/name` |
| `component` | `app.kubernetes.io/component` |
| `instance` | `app.kubernetes.io/instance` |
| `app` | `app` |

Precedence: entry `selector` > rule `selector` > `name`.

### The reserved key `any`

| Where | Meaning |
|---|---|
| `ingress.any` | the rule applies to every pod in this namespace |
| `egress.any` | traffic from every pod in this namespace |
| `from.any` / `to.any` + `namespace: X` | every pod in namespace X |
| `from.any` / `to.any` + `namespace: any` | every pod in every namespace |
| `from.<workload>` + `namespace: any` | pods with that label in any namespace |

`any` can't be used as a workload name. `namespace: any` on a named workload without a
`serviceAccount` produces a NOTES.txt warning: at the NetworkPolicy layer it trusts a label
anyone can set.

### Predefined sources and destinations

Defined in `templates/_presets.tpl`, not in `values.yaml`, so the chart knows which fields a
user set. A user entry is merged field by field over the preset, with these rules:

- Setting `namespace`, `workload`, or `podSelector` makes the entry in-cluster and drops the
  preset's `cidrs`.
- Setting `cidrs` makes it outside the cluster and drops the preset's in-cluster fields
  (`namespace`, `workload`, `selector`, `podSelector`, `serviceAccount`).
- `workload` and `podSelector` replace each other.
- One user entry can't set both `cidrs` and an in-cluster field, both `workload` and
  `podSelector`, or `selector` with `podSelector`; each is a `fail`.

Users can also add new names. A new in-cluster entry needs `workload` or `podSelector`, and
a new destination needs `ports`. `any` can't be used as a source or destination name.

An entry is either **outside the cluster** (`cidrs`) or **inside** (`namespace` plus
`workload` and optional `selector`, or a raw `podSelector`). `workload: any` means every pod
in the namespace, and an omitted `namespace` means this namespace. Never express an in-cluster
target with `cidrs`: NetworkPolicy `ipBlock` is meant for cluster-external addresses, and
Cilium doesn't match pods with it at all.

"Private ranges" below means 10.0.0.0/8, 172.16.0.0/12, and 192.168.0.0/16.

| Destination | Default | Ports |
|---|---|---|
| `dns` | `kube-system`, podSelector `k8s-app: kube-dns` | 53/UDP, 53/TCP |
| `kube-api` | private ranges | 443, 6443 |
| `postgres` | private ranges | 5432 |
| `redis` | private ranges | 6379 |
| `https` | private ranges | 443 |
| `sso` | private ranges | 443, 8443 |
| `storage` | private ranges | 443, 9000 |
| `ldap` | private ranges | 389, 636 |
| `smtp` | private ranges | 25, 587 |
| `ntp` | private ranges | 123/UDP |
| `syslog` | private ranges | 514/UDP, 514/TCP, 6514 |
| `egress-gateway` | namespace `gateway`, every pod | 15008 (HBONE); `mesh: istio` only, other meshes `fail` |

| Source | Default |
|---|---|
| `monitoring` | namespace `prometheus`, workload `prometheus`, serviceAccount `prometheus` |
| `ingress-gateway` | namespace `gateway`, every pod |

A destination carries its own ports; a source reference carries the ports on the target,
because only the target knows which port is being reached.

Preset defaults assume one namespace per application, named after it (`prometheus`,
`keycloak`), which matches most charts' installation instructions. Gateway presets use the
mesh-neutral namespace `gateway`.

`egress-gateway` exists because, with Istio ambient, traffic to a hostname routed through the
egress waypoint leaves the pod as HBONE to the waypoint, so the NetworkPolicy has to allow
that hop. Cilium's egress gateway reroutes at the node, and Linkerd has none, so neither needs
this destination.

## Rendering rules (network policies)

- `networkPolicy.<direction>`: each enabled direction is default-deny, one NetworkPolicy
  per direction with `podSelector: {}`. A disabled direction renders **nothing**: no deny,
  no fixed allows, no rules (they're still validated, stay in the model, and other layers
  still use them). It's a troubleshooting switch, and NOTES.txt says so loudly.
  A direction can't be partly managed: any NetworkPolicy that selects a pod for a direction
  already denies everything else in that direction, so `allowDNS` alone (every pod) would
  make egress default-deny anyway.
- `allowSameNamespace`: one NetworkPolicy allowing ingress from and egress to `podSelector: {}`.
- `allowDNS`: one NetworkPolicy, egress from every pod to the `dns` destination.
- Each pair of target and peer renders its own NetworkPolicy: one per `from` entry and per
  `sources` reference under `ingress.<key>`, and one per `to` entry and per `destinations`
  reference under `egress.<key>`. Names follow the convention below.
- Peer translation:
  - workload, namespace omitted: `podSelector` only
  - workload + `namespace: X`: `podSelector` + `namespaceSelector` on
    `kubernetes.io/metadata.name: X`
  - workload + `namespace: any`: `podSelector` + `namespaceSelector: {}`
  - `any` + `namespace: X`: `namespaceSelector` only
  - `any` + `namespace: any`: `namespaceSelector: {}`
  - `cidrs`: one `ipBlock` per CIDR
- `mesh: istio` (ambient) changes NetworkPolicies only, never authorization policies:
  - **TCP 15008 (HBONE) is added to every rule whose peer is inside the cluster**, ingress
    and egress, alongside the listed ports and with the same peers. Meshed traffic travels
    between pods as HBONE on 15008, so without it the listed ports would never match. Rules
    whose peer is `cidrs` (outside the cluster, so not meshed) don't get it. Duplicates are
    removed (the `egress-gateway` destination already lists 15008).
  - **Kubelet probes:** in ambient mode probes arrive from `169.254.7.127/32`, so one fixed
    NetworkPolicy allows ingress from that address to every pod.
  - Authorization policies list only the user's ports. They are enforced after ztunnel
    unwraps HBONE, where the original destination port is visible.

## Rendering rules (authorization, Istio ambient)

Rendered when `mesh: istio` and `authorization.enabled`, independently of `networkPolicy`.
Only `ingress` produces authorization policies: they're enforced at the destination, so
`egress` stays NetworkPolicy-only (under ambient, an egress port limit to a meshed peer holds
only where the destination's own authorization enforces it).

- `deny-all-ingress`: an AuthorizationPolicy with an empty spec (allow-nothing) for the
  namespace.
- `allowSameNamespace`: `allow-same-namespace`, ALLOW from `namespaces: [<this namespace>]`,
  every port.
- One ALLOW per ingress rule, named like the NetworkPolicy from the same rule, with
  `selector.matchLabels` from the target (none for `any`). Peers map to `from.source`:

  | Peer | `source` |
  |---|---|
  | `serviceAccount`, namespace omitted or X | `principals: [<trustDomain>/ns/<ns>/sa/<sa>]` |
  | `serviceAccount`, `namespace: any` | `principals: ["*/sa/<sa>"]` |
  | workload without `serviceAccount`, namespace omitted or X | `namespaces: [<ns>]` (NOTES warning) |
  | workload without `serviceAccount`, `namespace: any` | `principals: ["*"]` (NOTES warning) |
  | `any` + namespace omitted or X | `namespaces: [<ns>]` |
  | `any` + `namespace: any` | `principals: ["*"]` |
  | `cidrs` | one entry per CIDR: `ipBlocks: [<cidr>]`, `notIpBlocks: <except>` |

- Ports: `to.operation.ports`, TCP only (ztunnel carries no UDP or SCTP, which the
  NetworkPolicy enforces on the real port), never 15008, ranges expanded port by port, at most
  1024 per rule (more is a `fail`). A rule with no TCP ports renders no authorization policy.
- Identity rules only admit meshed clients; plaintext clients get in only where mTLS accepts
  plaintext (see mTLS below) or through a `cidrs` rule.

## Rendering rules (mTLS, Istio ambient)

Rendered when `mesh: istio`; nothing for `mode: inherit`.

- `mtls-<mode>` (`mtls-strict`, `mtls-permissive`): the namespace PeerAuthentication.
- Per exclusion (STRICT only), `allow-plaintext-to-<workload>`: a PeerAuthentication selecting
  the workload, `mtls.mode: STRICT` with `portLevelMtls` PERMISSIVE on the listed ports. Never
  DISABLE: an excluded port still uses mTLS when the client offers it.
- Authorization agrees (when it renders): wherever plaintext is accepted it admits clients
  without a mesh identity (`notPrincipals: ["*"]`): `allow-plaintext-to-<workload>` on the
  excluded ports, or under PERMISSIVE the namespace-wide `allow-plaintext-to-all`. The
  NetworkPolicies decide which plaintext peers get in; plaintext isn't HBONE, so they see its
  real port.
- Under STRICT, a `cidrs` source must target excluded ports (same target selector), or the
  render fails; into target `any` it can't, and the message suggests PERMISSIVE.
- `exclusions` with PERMISSIVE or inherit, or with `mesh: none`, fail.

## Rendering rules (policy exceptions)

Independent of `mesh`. The admission policies and the `PolicyExceptions` CRD
(`policyexceptions.policy.posture.dev`) belong to the separate policy chart
(github.com/jimmybchopps/policy), which owns the CRD; posture only renders the object, and
pins to a policy release for its tests (Makefile `POLICY_VERSION`, checksums verified). Each
policy's bindings read `paramRef: { name: posture-exceptions, parameterNotFoundAction: Deny }`
from the admitted object's namespace and match the pod's labels against `matchLabels` (the
CEL is the policy chart's; see its CLAUDE.md, "Exceptions").

- `posture-exceptions` is rendered whenever `policyExceptions.enabled`, **even empty**
  (`spec.exceptions: []`): the policies deny pods in a namespace without it (fail closed).
- Values are inverted to policy -> workloads: one entry per policy (sorted by kind, then name),
  each with one `matchLabels` per workload (sorted by key; one label, from `selector`), plus
  `reason` and `expires` when set.
- `enabled: false` entries are left out. Entries whose `expires` is before the render date
  (UTC) are left out and listed in a NOTES.txt warning; the expiry day itself still counts.
- Fails: non-empty `exceptions` with `policyExceptions.enabled: false`; an `expires` that isn't
  a real date; more than the CRD allows (256 policies, 64 workloads per policy).
- The schema mirrors the CRD: policy names are DNS labels up to 63 characters, `reason` at most
  1024 characters, `expires` `YYYY-MM-DD`.

## Naming

Every generated object, of every kind, is named for what it allows, read left to right:

    allow-<direction>-from-<source>-to-<destination>

| Rule | Name |
|---|---|
| `ingress.grafana.from.prometheus` | `allow-ingress-from-prometheus-to-grafana` |
| `ingress.grafana.sources.monitoring` | `allow-ingress-from-monitoring-to-grafana` |
| `ingress.grafana.from.any` + `namespace: tooling` | `allow-ingress-from-all-in-tooling-to-grafana` |
| `ingress.grafana.from.any` + `namespace: any` | `allow-ingress-from-all-namespaces-to-grafana` |
| `ingress.any.from.prometheus` | `allow-ingress-from-prometheus-to-all` |
| `egress.grafana.to.keycloak` | `allow-egress-from-grafana-to-keycloak` |
| `egress.grafana.destinations: [postgres]` | `allow-egress-from-grafana-to-postgres` |
| `egress.prometheus.to.any` + `namespace: any` | `allow-egress-from-prometheus-to-all-namespaces` |

Tokens: a map key is used as is; `any` as a target or source is `all`; `any` as a peer is
`all-in-<namespace>`, `all-namespaces`, or `all` (namespace omitted).

Fixed objects use the same style:

| Object | Name |
|---|---|
| default deny (`networkPolicy.<direction>`) | `deny-all-ingress`, `deny-all-egress` (one object per direction) |
| `allowSameNamespace` | `allow-same-namespace` |
| `allowDNS` | `allow-egress-from-all-to-dns` |
| Istio ambient kubelet probes | `allow-ingress-from-ambient-probes-to-all` |
| Istio allow-nothing policy | `deny-all-ingress` (AuthorizationPolicy) |
| mTLS | `mtls-<mode>` for the namespace; `allow-plaintext-to-<workload>` per exclusion (PeerAuthentication and AuthorizationPolicy) |
| Plaintext under PERMISSIVE | `allow-plaintext-to-all` (AuthorizationPolicy) |
| exceptions | `posture-exceptions` (PolicyExceptions, `policy.posture.dev/v1alpha1`); never prefixed |

Rules:

- **The same name across kinds is intended.** The NetworkPolicy and the AuthorizationPolicy
  generated from one rule share its name, so they're easy to find together.
- **No release prefix.** Only one `posture` release exists per namespace, so names stay
  readable. A `namePrefix` value (default empty) is there for anyone who needs one. It never
  applies to `posture-exceptions`, which the admission policies look up by that exact name.
- **Keys must be valid name parts.** Lowercase letters, digits, and `-`; anything else is a
  schema error rather than being silently rewritten.
- **Collisions fail.** If two rules produce the same name (for example, a `from` key and a
  source preset that are both called `monitoring`), the render fails and names both rules.
- **Length.** These kinds allow names up to 253 characters, so truncation should never
  happen; `posture.name` still enforces the limit and fails with the offending rule.

## Layout

```
charts/posture/
  Chart.yaml  values.yaml  values.schema.json
  templates/
    _helpers.tpl          the naming convention (posture.name), labels, collision checks
    _presets.tpl          predefined sources and destinations
    _model.tpl            values -> normalized model (selectors, peers, ports, presets merged)
    networkpolicy/        default-deny, same-namespace, ambient-probes, rules (every model
                          rule, allowDNS included), _networkpolicy.tpl (peer and port helpers)
    validate.yaml         builds the model on every render so bad values always fail
    istio/                authorizationpolicy (phase 2), peerauthentication (phase 3),
                          _authorization.tpl (object, peer and port helpers)
    linkerd/  cilium/     phase 6 (Linkerd), phase 7 (Cilium)
    exceptions/           the PolicyExceptions object (posture-exceptions)
    NOTES.txt
  tests/                  helm-unittest suites, one folder per output
examples/                 complete values files that double as e2e fixtures
test/e2e/                 k3d scripts: allowed traffic connects, denied traffic doesn't
test/model-probe/         test-only chart that prints the model for helm-unittest
test/crd-schema/          test-only chart that turns the pinned policy release's PolicyExceptions
                          CRD into the JSON schema kubeconform uses (make crd-schema)
docs/PLAN.md              build order and open questions
```

## Testing

`make tools` installs the pinned versions into `.bin/`; `make test` runs lint, unit tests, and
kubeconform; `make test-all-helm` repeats that under every supported Helm version. The
underlying commands:

    helm lint --strict charts/posture
    helm unittest charts/posture                      # plugin: helm-unittest
    make policy-release                               # fetch + verify the pinned policy chart
                                                      # (CRD and package) into .bin/
    helm template t charts/posture -f examples/<x>.yaml | kubeconform -strict -summary \
      -schema-location default \
      -schema-location '.bin/schemas-policy-<version>/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    make e2e MESH=none|istio                          # test/e2e/run.sh; needs Docker
                                                      # E2E_KEEP=1 keeps the cluster,
                                                      # E2E_ARGS=strict runs one scenario
    make unittest-update                              # regenerate example snapshots

helm-unittest reads an unquoted date in a values file (`expires: 2027-03-31`) as a timestamp,
where Helm keeps it a string, so test values quote dates and `make lint` checks the unquoted
form with real Helm.

Snapshots of every example's output are committed under `charts/posture/tests/__snapshot__/`;
review the diff before updating them.

Every feature gets unit tests for each `mesh` value it affects, including the `fail` cases. A
rule change isn't done until an e2e case shows the allowed path connects and a denied path
doesn't. k3d clusters for e2e must use Calico or Cilium: k3s's default flannel doesn't enforce
NetworkPolicy.

Every posture install renders `posture-exceptions`, so every e2e run needs the pinned
PolicyExceptions CRD. How it gets there depends on the mesh:

- `MESH=none`: run.sh applies the CRD; only the `exceptions` scenario installs the policy
  chart, and uninstalls it in its teardown.
- Any mesh: the policy chart goes in after Calico and before the mesh, as on a real cluster,
  and stays for the whole run. Then come istio-system's exceptions, rendered by posture
  itself from `test/e2e/values/istio-system.yaml` (add an entry there when a mesh workload is
  refused), then Istio, with istio-cni in `kube-system`, which the policies never evaluate.
  Each scenario namespace gets an empty `posture-exceptions` when it's created (pods there are
  denied without one), and `install_posture` adopts it with `--take-ownership`.

e2e workloads meet the policy chart's baseline under every mesh. Images are listed fully
qualified, because `restrict-image-registries` matches plain prefixes
(`test/e2e/values/policy.yaml`).

## Status

| Phase | Area | Status |
|---|---|---|
| 0 | Repo setup, tooling, CI | done |
| 1 | Network policies | done (see docs/PLAN.md 1c, "Accepted failures") |
| 2 | Authorization policies (Istio first) | done (one egress wrong-port deny is a known failure until phase 5; see docs/PLAN.md 1c) |
| 3 | mTLS with per-port exclusions | done |
| 4 | Policy exceptions | done, except the first e2e run (see docs/PLAN.md phase 4) |
| 5 | Boundary integration and egress hostnames (Istio) | not started |
| 6 | Linkerd renderer | not started |
| 7 | Cilium renderer | not started |
