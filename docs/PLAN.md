# posture: development plan

Build order: network policies, then authorization policies generated from the same rules, then
mTLS, then policy exceptions, then integration with the `boundary` chart and egress to
hostnames (Istio), then the Linkerd and Cilium renderers. Istio ambient (L4) is the
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
  `linkerd` and `cilium` in phase 6, so a setting is never accepted and silently ignored.
- Tool versions are pinned in the `Makefile` only (one source of truth); `make tools` installs
  them into `.bin/`, with a separate Helm home per Helm version. CI tests Helm 3.14.4, the
  latest 3.x, and the latest 4.x. Helm 3.14 can't load helm-unittest 1.1.0 or later, so the
  Makefile uses 1.0.3 there.

---

## Phase 1: network policies

### 1a. Presets and the model

- [x] `_presets.tpl`: the predefined sources and destinations from CLAUDE.md.
- [x] Preset merging: user entries merge field by field over presets; an in-cluster field
      (`namespace`, `workload`, `podSelector`) drops the preset's `cidrs`; `cidrs` together
      with an in-cluster field in user values is a `fail`. New names are allowed.
- [x] `_model.tpl`: normalize `ingress` and `egress` into rules, each with its object name,
      direction, target `podSelector`, normalized peers, and normalized ports.
- [x] Selector resolution with the precedence entry > rule > `name`, mapping the short names
      to labels.
- [x] The reserved key `any`, for targets and for peers, with `namespace` omitted, set, or
      `any` (see the table in CLAUDE.md).
- [x] Ports: required and non-empty everywhere they appear; numbers or port objects with a
      numeric `port`; `protocol` defaults to TCP. Port names are a schema error.
- [x] Unknown preset references (`destinations: [postgress]`) `fail` with the list of known
      names.
- [x] Schema: selector enum, port shape, `any` not allowed as a `serviceAccount` or selector
      value, each `from`/`to` entry is either a workload entry or a `cidrs` entry.
      `endPort >= port` is checked in `_model.tpl` (draft-07 can't compare two fields).

Decisions made in 1a:

- Overrides work in both directions: `cidrs` on an in-cluster preset drops its namespace and
  workload, just as an in-cluster field drops a preset's `cidrs`.
- New in-cluster sources and destinations use `workload: any` for every pod in a namespace;
  `workload` (or `podSelector`) is required for new in-cluster entries.
- `podSelector` is only for source and destination definitions, not `from`/`to` entries.
- The preset `kubeAPI` is renamed `kube-api`: object names must be lowercase, and keys follow
  the same rule.
- `allowDNS` is an ordinary rule in the model (egress from `any` to `dns`), so its name comes
  from the convention and an overridden `dns` destination applies to it.
- `templates/validate.yaml` builds the model on every render, so bad values fail the install
  even before a renderer uses them.
- The model is tested directly through `test/model-probe/`, a test-only chart that depends on
  `charts/posture` and prints the model. Renderer tests in 1b and later can stay small.
- The schema accepts Helm's `global` key, which Helm adds when the chart is a dependency.

### 1b. Rendered policies

- [x] `deny-all-ingress`, `deny-all-egress`, `allow-same-namespace`,
      `allow-egress-from-all-to-dns`, and `allow-ingress-from-ambient-probes-to-all`
      (`mesh: istio` only).
- [x] `mesh: istio`: add TCP 15008 to every ingress and egress rule whose peer is inside the
      cluster (not to `cidrs` rules), deduplicated. NetworkPolicies only.
- [x] One NetworkPolicy per target and peer pair (each `from`/`to` entry and each
      `sources`/`destinations` reference), named `allow-<direction>-from-<source>-to-<destination>`.
- [x] Collision check: two rules producing the same name fail the render, naming both.
- [x] `posture.dev/rule` annotation on every object.
- [x] NOTES.txt warning: `namespace: any` on a named workload without `serviceAccount`.

Decisions made in 1b:

- `defaultDeny` is replaced by `networkPolicy: { ingress, egress }`, a per-direction
  troubleshooting switch. Any NetworkPolicy that selects a pod for a direction denies the rest
  of that direction, so `defaultDeny: false` never took effect while `allowDNS`,
  `allowSameNamespace`, or the probe policy were on. Off now means nothing at all is rendered
  for that direction; rules are still validated and stay in the model (phase 2 reads them).
  NOTES.txt warns loudly.
- The deny objects are annotated `networkPolicy.ingress` / `networkPolicy.egress`, and the
  probe policy `mesh`.
- The collision check lives in the model and covers fixed objects and every rule, including
  rules in a disabled direction, so names can't start colliding when a switch is flipped back.
- 15008 is skipped only when exactly TCP 15008 is listed; a range that covers it still gets
  it added (harmless).
- The untrusted-label NOTES warning covers egress peers and custom sources/destinations too.

### 1c. Tests and examples

- [x] Unit tests: every peer form in the translation list, every selector value and the
      precedence, every port form, preset overrides (cidrs only, ports only, switch to
      in-cluster, new name), the `fail` cases, every row of the naming tables in CLAUDE.md,
      the collision `fail`, and name stability when keys are added.
- [x] `examples/`:
      - `minimal.yaml`: defaults only
      - `prometheus.yaml`: the `prometheus` namespace, egress to every namespace on listed
        metrics ports
      - `grafana.yaml`: `ingress-gateway` and `monitoring` sources in, `postgres` and `sso` out
      - `strict.yaml`: `allowSameNamespace: false`
      - `istio.yaml`: `grafana.yaml` with `mesh: istio`
- [x] e2e on k3d (`test/e2e/`) with Calico (flannel disabled): deploy a server and client pods in two
      namespaces, apply each example, and check that allowed connections succeed and denied
      ones time out, including Prometheus scraping into another namespace. With
      `mesh: istio`, also check that meshed traffic on a listed port connects (15008 added),
      that a peer not in any rule can't get through over 15008, and that probes still pass.

**Done when** every example renders, validates with kubeconform, and passes e2e with
`mesh: none` and `mesh: istio`.

Decisions made in 1c:

- `prometheus.yaml` includes port 3000 so the e2e test can scrape Grafana across namespaces.
- The external host for the `cidrs` presets is a plain container on the k3d Docker network
  (a 172.x address, inside the private ranges), never a pod IP.
- e2e deny means "no HTTP response" rather than "timeout": under ambient, ztunnel can reset a
  blocked connection. Every scenario first runs all its checks without posture (baseline), so
  a deny can't pass because a server was broken.
- Example snapshots are committed (`charts/posture/tests/__snapshot__/`); update them with
  `make unittest-update` after reviewing the change.
- The Istio checks live in the `grafana-prometheus` scenario under `MESH=istio`. A meshed
  intruder's denied connection is the 15008 check (its HBONE to 15008 is what's blocked), and
  a grafana restart under the policy is the probe check.
- Calico is installed with the Tigera operator, following k3d's guide
  (https://k3d.io/v5.9.0/usage/advanced/calico/) as closely as possible: k3s gets
  `--cluster-cidr=192.168.0.0/16` to match the unmodified `custom-resources.yaml`. istio-cni
  uses its chart defaults (`/etc/cni/net.d`, `/opt/cni/bin`), which is where the operator puts
  Calico's CNI files; `global.platform=k3s` points elsewhere and must not be set.
- Istio charts come from `https://blob.istio.io/istio-release/charts`; 1.31 and later aren't
  published to the old `istio-release.storage.googleapis.com`, which shuts down on
  2026-12-16.
- Under `MESH=istio`, the harness restarts every workload after installing posture and before
  the policy checks. ztunnel pools the HBONE connections the baseline checks opened and sends
  later requests over them, and NetworkPolicy only judges new connections, so without the
  restart every in-cluster deny connected. ztunnel itself isn't restarted: that briefly breaks
  all meshed traffic, which a deny check would count as a pass. The same behaviour affects real
  clusters: under ambient, a stricter posture doesn't cut existing connections between meshed
  workloads until they reconnect.

**Accepted failures (until phase 2).** Phase 1 is complete with `mesh: none` passing in full
and `mesh: istio` passing everything except three wrong-port denies (48 passed, 3 failed):

- `strict`: `deny apps/web -> api.apps:8081`
- `grafana-prometheus`: `deny gateway/envoy -> grafana.grafana:3001`
- `grafana-prometheus`: `deny prometheus/prometheus -> x.intruder:8081`

Each peer is allowed on another port, so 15008 is open between the pair, and between meshed
pods Calico only ever sees 15008, never the original port. NetworkPolicy under ambient limits
which workloads can talk, not on which ports. The port limit is enforced by the phase 2
AuthorizationPolicies (ztunnel checks the original port after unwrapping HBONE). These checks
are left failing, with no changes to the harness or the chart, as phase 2's target. Until then
the `mesh: istio` e2e job in CI is expected to fail on exactly these three.

Phase 2 update: the first two are ingress port limits, which the AuthorizationPolicies now
enforce, and pass in the phase 2 e2e run. The third is an
*egress* port limit to a namespace without a posture release: authorization is enforced only
at the destination, and `intruder` has none, so nothing enforces that port under ambient. It
is accepted as a known failure past phase 2 (decided with the maintainer), to be resolved in
phase 5 (boundary integration). In general, under ambient, egress port limits to meshed
in-cluster peers hold only where the destination's own authorization enforces them.

---

## Phase 2: authorization policies (Istio ambient first)

Generated from `ingress` (authorization is enforced at the destination, so `egress` stays
NetworkPolicy-only). Enforced by ztunnel at L4.

- [x] When `mesh: istio` and `authorization.enabled`: a namespace-wide allow-nothing
      AuthorizationPolicy (empty spec) named `deny-all-ingress`.
- [x] `allowSameNamespace`: ALLOW from `namespaces: [<this namespace>]`, named
      `allow-same-namespace`.
- [x] One ALLOW policy per target and peer pair, with the same name as the NetworkPolicy from
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
- [x] Presets as sources follow the same table (a preset can carry a `serviceAccount`).
- [x] `authorization.enabled` (default true; used only when `mesh` isn't `none`, ignored with `none`).
- [x] Unit tests for every row and the `fail` cases (`tests/istio/authorizationpolicy_test.yaml`,
      plus NOTES, schema, and model-probe cases).
- [x] e2e (`identity`, `identity-authz-only`, `identity-netpol-only`): a pod with the right labels but the wrong service account is refused
      by the mesh even though the NetworkPolicy lets it through; test each layer with the other
      relaxed. The two ingress wrong-port denies accepted as failing in phase 1 (see "Accepted
      failures" under 1c) must pass under `MESH=istio`; the egress one is a known failure
      (phase 5). Passed: every check under `MESH=none` and `MESH=istio` except that one.

**Done when** e2e shows NetworkPolicy and AuthorizationPolicy each block traffic on their own.

Decisions made in phase 2:

- Only TCP ports go into AuthorizationPolicies. ztunnel carries TCP only, so UDP and SCTP
  bypass it and the NetworkPolicy enforces them on their real port. Listing a UDP port number
  would open that number for TCP too, so it's dropped; a rule with no TCP ports renders no
  AuthorizationPolicy.
- Port ranges are expanded port by port (`operation.ports` has no range form). A rule that
  would list more than 1024 ports fails, naming the rule.
- `cidrs` sources render one `from` entry per CIDR, so each `except` list (`notIpBlocks`) stays
  bound to its own CIDR.
- Identity rules (`principals`, `namespaces`) only admit meshed clients; a client in a namespace
  outside the mesh is refused even where a rule names it. NOTES.txt says so.
- The `monitoring` preset carries `serviceAccount: prometheus`, so it maps to an exact
  principal; installs that run Prometheus under another account override it
  (`sources.monitoring.serviceAccount`).
- The fixed `deny-all-ingress` AuthorizationPolicy's `posture.dev/rule` is
  `authorization.enabled`.
- e2e workloads each run as their own ServiceAccount, named after the workload. Deployments
  select their pods by `e2e.posture.dev/deployment`, so an impostor with copied labels never
  counts as the real workload. Scenarios can declare `SCENARIO_MESHES` to run only under
  some meshes.
- `make unittest` now passes `-f 'tests/*_test.yaml' -f 'tests/*/*_test.yaml'`: helm-unittest
  reads only `tests/*_test.yaml` by default, so the suites under `tests/networkpolicy/` had
  never run (one didn't even parse). They run, and pass, now.

---

## Phase 3: mTLS with per-port exclusions

```yaml
mtls:
  mode: STRICT              # STRICT (default) | PERMISSIVE | inherit (render nothing)
  exclusions:               # workload in this namespace -> ports that also accept plaintext
    grafana: [9090]
    renderer: { selector: instance, ports: [8081] }
```

Confirmed for Istio ambient: with the namespace at STRICT, a workload can set individual ports
to PERMISSIVE; disabling mTLS (`DISABLE`) on a port isn't supported. The chart follows that
everywhere:

- [x] Istio: a namespace PeerAuthentication `mtls-<mode>`; one workload PeerAuthentication per
      exclusion, `allow-plaintext-to-<workload>`, with `portLevelMtls` set to `PERMISSIVE` for
      the listed ports. `exclusions.any` is rejected (see the decisions below).
- [x] Exclusions are only valid with `mode: STRICT`; with `PERMISSIVE` or `inherit` they `fail`
      (every port already accepts plaintext, or the chart isn't managing mTLS).
- [x] There is no `DISABLE` anywhere: the schema rejects it as a mode, and exclusions always
      mean PERMISSIVE (mTLS still used when the client offers it).
- [x] Authorization agrees with mTLS: wherever plaintext is accepted, an AuthorizationPolicy
      admits clients without a mesh identity on those ports.
- [x] Unit tests (`tests/istio/peerauthentication_test.yaml`, plaintext cases in the
      authorization suite, model failures, schema, naming, NOTES, model-probe).
- [ ] e2e (scenarios written: `mtls-strict`, `mtls-permissive`; first real run pending): a
      client outside the mesh is refused on a strict port and connects on an excluded one,
      while a meshed client still connects with mTLS on the excluded port.

**Done when** the e2e matrix passes for strict, permissive, and excluded ports.

Decisions made in phase 3:

- `mtls.mode` defaults to STRICT. With `mesh: none` the block is ignored, except that non-empty
  exclusions `fail` (no mesh can provide them).
- Plaintext and authorization: phase 2's authorization admits in-cluster clients by mesh
  identity, which a plaintext client doesn't have. So wherever mTLS accepts plaintext,
  authorization admits clients without an identity (`source.notPrincipals: ["*"]`): one
  `allow-plaintext-to-<workload>` AuthorizationPolicy per exclusion on its ports (same name as
  its PeerAuthentication), and under PERMISSIVE one namespace-wide `allow-plaintext-to-all`.
  The NetworkPolicies decide which plaintext peers get in: plaintext isn't HBONE, so they see
  its real port. Meshed clients still need their identity rules. Under `inherit` the chart
  doesn't know the mesh-wide mode, so it adds no plaintext policy.
- Under STRICT, an ingress rule whose source is `cidrs` (outside the cluster, never mTLS) must
  have every TCP port covered by an exclusion selecting the same target; otherwise the render
  fails, naming the rule and port. A `cidrs` source into target `any` can't be covered and
  fails, suggesting PERMISSIVE. UDP ports are ignored (no mTLS on UDP).
- `exclusions.any` is rejected by the schema: Istio applies `portLevelMtls` only to a
  PeerAuthentication with a workload selector (one without a selector is the namespace-wide
  policy), so "every pod, these ports" can't be expressed. Exclusions name the workloads that
  need it. This is unrelated to `from.any`/`to.any` in traffic rules: a meshed scraper (for
  example Prometheus checked by its service account) needs no exclusion at all.
- Exclusion ports are plain numbers (no protocol, no range): `portLevelMtls` keys are single
  TCP ports. An exclusion is a list, or `{ selector, ports }` to match another label.
- e2e: `MESHED=0 namespace <name>` creates a namespace outside the mesh. Removing an exclusion
  from an example on the command line takes `--set-json 'mtls.exclusions={}'`; `--set ...=null`
  reaches schema validation as a literal null and fails.

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

## Phase 5: boundary integration and egress hostnames (Istio)

`boundary` is a separate chart for the cluster-wide pieces: ingress and egress gateways,
approved external hostnames, and mesh-wide resources. posture never references or depends on
it and stays namespace-scoped; the two meet only in e2e, where both are installed. Istio only
for now; other meshes follow in phase 6.

- [ ] The e2e harness installs `boundary` alongside Istio.
- [ ] Egress to hostnames under `mesh: istio`: a values shape for limiting a workload's egress
      to named hosts approved by `boundary`, rendered with the existing `egress-gateway`
      destination (HBONE 15008 to the egress waypoint) plus whatever per-namespace objects
      Istio needs, all in the release namespace. Any other mesh `fail`s, naming the rule.
- [ ] Resolve the remaining accepted failure (`deny prometheus/prometheus -> x.intruder:8081`,
      an egress port limit into a namespace without posture; see "Accepted failures" under 1c).
- [ ] Unit tests (schema, model, renderer, the non-istio `fail`) and e2e: an approved host
      connects; an unapproved host, and a direct path that skips the gateway, don't.

**Done when** the integration e2e passes under `MESH=istio` with no accepted failures.

Open questions, settled at the start of the phase:

- Where `boundary` lives and how the e2e harness installs it.
- The values shape for egress to hostnames.
- Which objects belong to posture (per namespace) and which to `boundary` (cluster-wide).
- How the remaining accepted failure is resolved.

---

## Phase 6: Linkerd and Cilium

- [ ] Linkerd: a `Server` per target port; `AuthorizationPolicy` with `MeshTLSAuthentication`
      (identity `<sa>.<ns>.serviceaccount.identity.linkerd.<trustDomain>`) or
      `NetworkAuthentication` for `cidrs`; mTLS via `Server.spec.accessPolicy`
      (`all-authenticated`, or `all-unauthenticated` for excluded ports).
- [ ] Cilium: `networkPolicy.provider: cilium` renders `CiliumNetworkPolicy` instead of NetworkPolicy;
      identity rules match `io.cilium.k8s.policy.serviceaccount`; strict mTLS requires Cilium
      mutual authentication, or `fail`s unless the values explicitly accept encryption-only.
- [ ] Cilium as the gateway: Cilium's Gateway API traffic arrives from its shared Envoy with
      the reserved `ingress` identity, not from pods in a `gateway` namespace. When the
      cluster uses Cilium's gateway, the `ingress-gateway` source renders as
      `fromEntities: [ingress]` (needs `networkPolicy.provider: cilium`).
- [ ] Linkerd and Cilium `fail` on the `egress-gateway` destination with an explanation (it
      only exists for Istio's egress waypoint).
- [ ] Golden files: one example, three meshes, reviewed side by side.

---

## Open questions

1. **Exceptions format (phase 4).** Deferred: agree on the shape with the admission policies'
   CEL, and on how a policy treats a missing parameter object.

2. **An escape hatch for custom resources (deferred, after phase 6).** The generated rules
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
