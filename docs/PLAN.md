# posture: development plan

Build order: network policies, then authorization policies generated from the same rules, then
mTLS, then policy exceptions, then the Linkerd and Cilium renderers. Istio ambient (L4) is the
first mesh for phases 2 and 3. The values contract is in `CLAUDE.md`; this file says what to
build and how to know it's done.

Each phase ends with its acceptance criteria passing in CI.

---

## Phase 0: repository setup

- [x] `charts/posture/` with `Chart.yaml` (apiVersion v2, type application, version 0.1.0),
      `values.yaml` documenting every key with comments, a `values.schema.json` skeleton, and
      `_helpers.tpl` with labels and `posture.name`, the naming convention from CLAUDE.md
      (tokens for `any`, optional `namePrefix`, length check).
- [x] Tooling: helm-unittest plugin, kubeconform, k3d. Pin versions in a `Makefile` or
      `.tool-versions`.
- [x] CI (GitLab or GitHub, wherever the repo lives): `helm lint --strict`, `helm unittest`,
      kubeconform over every file in `examples/`. The e2e job is added in phase 1.
- [x] Support Helm 3 (3.14 or later) and Helm 4; run unit tests under both.

**Done when** an empty install lints, templates to the default objects only, and CI is green.

Decisions made in phase 0:

- The default install renders **no objects** in phase 0; the four default objects arrive in 1b,
  which updates `tests/defaults_test.yaml` to expect them.
- `values.yaml` and the schema accept only keys that are implemented. Each phase adds its own
  keys (`authorization`, `mtls`, `exceptions`, `networkPolicy`), and the `mesh` enum grows to
  `linkerd` and `cilium` in phase 5, so a setting is never accepted and silently ignored.
- Tool versions are pinned in the `Makefile` only (one source of truth); `make tools` installs
  them into `.bin/`, with a separate Helm home per Helm version. CI tests Helm 3.14.4, the
  latest 3.x, and the latest 4.x. Helm 3.14 can't load helm-unittest 1.1.0 or later, so the
  Makefile uses 1.0.3 there.

---

## Phase 1: network policies

### 1a. Presets and the model

- [ ] `_presets.tpl`: the predefined sources and destinations from CLAUDE.md.
- [ ] Preset merging: user entries merge field by field over presets; an in-cluster field
      (`namespace`, `workload`, `podSelector`) drops the preset's `cidrs`; `cidrs` together
      with an in-cluster field in user values is a `fail`. New names are allowed.
- [ ] `_model.tpl`: normalize `ingress` and `egress` into rules, each with its object name,
      direction, target `podSelector`, normalized peers, and normalized ports.
- [ ] Selector resolution with the precedence entry > rule > `name`, mapping the short names
      to labels.
- [ ] The reserved key `any`, for targets and for peers, with `namespace` omitted, set, or
      `any` (see the table in CLAUDE.md).
- [ ] Ports: required and non-empty everywhere they appear; numbers or port objects with a
      numeric `port`; `protocol` defaults to TCP. Port names are a schema error.
- [ ] Unknown preset references (`destinations: [postgress]`) `fail` with the list of known
      names.
- [ ] Schema: selector enum, port shape, `endPort >= port`, `any` not allowed as a
      `serviceAccount` or selector value, each `from`/`to` entry is either a workload entry
      or a `cidrs` entry.

### 1b. Rendered policies

- [ ] `deny-all-ingress`, `deny-all-egress`, `allow-same-namespace`,
      `allow-egress-from-all-to-dns`, and `allow-ingress-from-ambient-probes-to-all`
      (`mesh: istio` only).
- [ ] `mesh: istio`: add TCP 15008 to every ingress and egress rule whose peer is inside the
      cluster (not to `cidrs` rules), deduplicated. NetworkPolicies only.
- [ ] One NetworkPolicy per target and peer pair (each `from`/`to` entry and each
      `sources`/`destinations` reference), named `allow-<direction>-from-<source>-to-<destination>`.
- [ ] Collision check: two rules producing the same name fail the render, naming both.
- [ ] `posture.dev/rule` annotation on every object.
- [ ] NOTES.txt warning: `namespace: any` on a named workload without `serviceAccount`.

### 1c. Tests and examples

- [ ] Unit tests: every peer form in the translation list, every selector value and the
      precedence, every port form, preset overrides (cidrs only, ports only, switch to
      in-cluster, new name), the `fail` cases, every row of the naming tables in CLAUDE.md,
      the collision `fail`, and name stability when keys are added.
- [ ] `examples/`:
      - `minimal.yaml`: defaults only
      - `prometheus.yaml`: the `prometheus` namespace, egress to every namespace on listed
        metrics ports
      - `grafana.yaml`: `ingress-gateway` and `monitoring` sources in, `postgres` and `sso` out
      - `strict.yaml`: `allowSameNamespace: false`
      - `istio.yaml`: `grafana.yaml` with `mesh: istio`
- [ ] e2e on k3d with Calico (flannel disabled): deploy a server and client pods in two
      namespaces, apply each example, and check that allowed connections succeed and denied
      ones time out, including Prometheus scraping into another namespace. With
      `mesh: istio`, also check that meshed traffic on a listed port connects (15008 added),
      that a peer not in any rule can't get through over 15008, and that probes still pass.

**Done when** every example renders, validates with kubeconform, and passes e2e with
`mesh: none` and `mesh: istio`.

---

## Phase 2: authorization policies (Istio ambient first)

Generated from `ingress` (authorization is enforced at the destination, so `egress` stays
NetworkPolicy-only). Enforced by ztunnel at L4.

- [ ] When `mesh: istio` and `defaultDeny.ingress`: a namespace-wide allow-nothing
      AuthorizationPolicy (empty spec) named `deny-all-ingress`.
- [ ] `allowSameNamespace`: ALLOW from `namespaces: [<this namespace>]`, named
      `allow-same-namespace`.
- [ ] One ALLOW policy per target and peer pair, with the same name as the NetworkPolicy from
      that rule (no selector when the target is `any`). The peer maps to `from.source` as follows:

      | Peer | `from.source` |
      |---|---|
      | workload + `serviceAccount`, namespace X | `principals: [<trustDomain>/ns/X/sa/<sa>]` |
      | workload + `serviceAccount`, `namespace: any` | `principals: ["*/sa/<sa>"]` |
      | workload without `serviceAccount`, namespace X | `namespaces: [X]`, with a NOTES warning |
      | workload without `serviceAccount`, `namespace: any` | `principals: ["*"]` (any mesh identity), with a NOTES warning |
      | `any` + namespace X | `namespaces: [X]` |
      | `any` + `namespace: any` | `principals: ["*"]` |
      | `cidrs` | `ipBlocks` / `notIpBlocks` |

      `to.operation.ports` from the rule's ports, never including 15008 (ztunnel enforces
      authorization on the original destination port, after unwrapping HBONE).
- [ ] Presets as sources follow the same table (a preset can carry a `serviceAccount`).
- [ ] `authorization.enabled` (default true when `mesh` isn't `none`).
- [ ] Unit tests for every row and the `fail` cases. e2e: a pod with the right labels but the
      wrong service account is refused by the mesh even though the NetworkPolicy lets it
      through; test each layer with the other relaxed.

**Done when** e2e shows NetworkPolicy and AuthorizationPolicy each block traffic on their own.

---

## Phase 3: mTLS with per-port exclusions

```yaml
mtls:
  mode: STRICT              # STRICT | PERMISSIVE | inherit (render nothing)
  exclusions:               # workload (or any) -> ports that also accept plaintext
    grafana: [9090]
```

Confirmed for Istio ambient: with the namespace at STRICT, a workload can set individual ports
to PERMISSIVE; disabling mTLS (`DISABLE`) on a port isn't supported. The chart follows that
everywhere:

- [ ] Istio: a namespace PeerAuthentication `mtls-<mode>`; one workload PeerAuthentication per
      exclusion, `allow-plaintext-to-<workload>` (`allow-plaintext-to-all` for `any`), with
      `portLevelMtls` set to `PERMISSIVE` for the listed ports.
- [ ] Exclusions are only valid with `mode: STRICT`; with `PERMISSIVE` or `inherit` they `fail`
      (every port already accepts plaintext, or the chart isn't managing mTLS).
- [ ] There is no `DISABLE` anywhere: the schema rejects it as a mode, and exclusions always
      mean PERMISSIVE (mTLS still used when the client offers it).
- [ ] Unit tests; e2e: a client outside the mesh is refused on a strict port and connects on
      an excluded one, while a meshed client still connects with mTLS on the excluded port.

**Done when** the e2e matrix passes for strict, permissive, and excluded ports.

---

## Phase 4: policy exceptions

Exceptions to the cluster's admission policies, declared by the namespace that needs them.
The policies live elsewhere (in Neutron Star, the core `policy` bundle); this chart renders
the per-namespace exceptions object they read as parameters.

```yaml
exceptions:
  legacy-agent-root:                  # a name for the exception
    policy: require-non-root          # the admission policy's name
    workload: legacy-agent            # optional; omit for the whole namespace
    selector: name                    # optional
    kinds: [Deployment]               # optional
    reason: "Vendor image runs as root; ticket OPS-123"
    expires: 2027-03-31               # required
```

- [ ] Render one ConfigMap named `posture-exceptions` holding the list, in the format the
      policies expect (open question 3).
- [ ] `reason` and `expires` are required (schema). Expired entries are listed in NOTES.txt
      and fail the render when `exceptionsFailOnExpired: true` (sprig `now`, `toDate`).
- [ ] The ConfigMap must be adoptable: Neutron Star's installer creates it empty, with Helm
      ownership annotations, before this chart installs. Unit-test its name and labels so
      they can't drift.
- [ ] e2e with a sample ValidatingAdmissionPolicy that reads parameters from the admitted
      object's namespace: an exempt workload is admitted, a non-exempt one is denied, and a
      namespace with no exceptions object at all gets the full policy (never "skip the
      policy").

**Done when** that e2e passes, including the missing-object case.

---

## Phase 5: Linkerd and Cilium

- [ ] Linkerd: a `Server` per target port; `AuthorizationPolicy` with `MeshTLSAuthentication`
      (identity `<sa>.<ns>.serviceaccount.identity.linkerd.<trustDomain>`) or
      `NetworkAuthentication` for `cidrs`; mTLS via `Server.spec.accessPolicy`
      (`all-authenticated`, or `all-unauthenticated` for excluded ports).
- [ ] Cilium: `networkPolicy: cilium` renders `CiliumNetworkPolicy` instead of NetworkPolicy;
      identity rules match `io.cilium.k8s.policy.serviceaccount`; strict mTLS requires Cilium
      mutual authentication, or `fail`s unless the values explicitly accept encryption-only.
- [ ] Cilium as the gateway: Cilium's Gateway API traffic arrives from its shared Envoy with
      the reserved `ingress` identity, not from pods in a `gateway` namespace. When the
      cluster uses Cilium's gateway, the `ingress-gateway` source renders as
      `fromEntities: [ingress]` (needs `networkPolicy: cilium`).
- [ ] Linkerd and Cilium `fail` on the `egress-gateway` destination with an explanation (it
      only exists for Istio's egress waypoint).
- [ ] Golden files: one example, three meshes, reviewed side by side.

---

## Open questions

1. **Exceptions format (phase 4).** Deferred: agree on the shape with the admission policies'
   CEL, and on how a policy treats a missing parameter object.

2. **An escape hatch for custom resources (deferred, after phase 5).** The generated rules
   will eventually meet a case they can't express (an L7 rule on a waypoint, an unusual
   Cilium selector, a vendor-specific policy). Users need a way to add their own objects
   without forking the chart, but a fully open "any manifest" field would let this chart
   create cluster-scoped objects and anything else, breaking the namespace-scoped principle.
   Options:

   - **A. Fully open `extraObjects`:** a map of raw manifests rendered as given. Common in
     charts, simplest, but no guardrails.
   - **B. Restricted `extraObjects`** (leaning this way): the same map, but each object must
     be a kind on an allow list (NetworkPolicy, AuthorizationPolicy, PeerAuthentication,
     Linkerd Server and AuthorizationPolicy, CiliumNetworkPolicy, and so on), is forced into
     the release namespace, and can't be cluster-scoped. Anything else `fail`s with the list
     of allowed kinds.
   - **C. Per-rule overrides:** extra fields merged into a generated object
     (`ingress.grafana.from.prometheus.override: {...}`). Precise, but couples users to the
     generated shape, which then can't change freely.

   Whichever is chosen: keyed by name (a map, so overrides merge), annotated
   `posture.dev/rule: extraObjects.<key>` so it's clear these weren't generated, listed in
   NOTES.txt, and exempt from the "never silently weaker" check, since the chart can't
   judge hand-written objects.

### Settled

- Ports are always required and always numeric. There is no "all ports" form and no named
  ports.
- Under Istio ambient, TCP 15008 is added to every in-cluster NetworkPolicy rule alongside
  its ports; authorization policies list only the user's ports.
- Istio ambient supports port-level PERMISSIVE under a STRICT namespace, and not DISABLE
  (phase 3 reflects this).
- Gateway presets use the mesh-neutral namespace `gateway`: `ingress-gateway` as a source,
  `egress-gateway` (Istio only) as a destination.
- The `monitoring` source defaults to namespace `prometheus`, workload `prometheus`. Presets
  assume one namespace per application, named after it.
