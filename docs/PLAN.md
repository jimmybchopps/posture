# posture: development plan

Build order: network policies, then authorization policies generated from the same rules, then
mTLS, then policy exceptions, then integration with the `boundary` chart and egress to
hostnames (Istio), then the Linkerd renderer, then the Cilium renderer. Istio ambient (L4) is the
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
  `linkerd` in phase 6 and `cilium` in phase 7, so a setting is never accepted and silently
  ignored.
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
- [x] Unknown preset references (`destinations: { postgress: {} }`) `fail` with the list of known
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
  is installed in `kube-system` (required on GKE, and the preferred namespace after
  istio-system) and uses its chart defaults (`/etc/cni/net.d`, `/opt/cni/bin`), which is where the operator puts
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
- [x] e2e (`mtls-strict`, `mtls-permissive`): a client outside the mesh is refused on a strict
      port and connects on an excluded one, while a meshed client still connects with mTLS on
      the excluded port. Passed: every check under `MESH=none` and `MESH=istio` except the
      known egress failure left for phase 5.

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

Exceptions to the cluster's admission policies (native ValidatingAdmissionPolicy and
MutatingAdmissionPolicy), declared by the namespace that needs them. The policies, their
bindings, and the `PolicyExceptions` CRD belong to the separate policy chart
(https://github.com/jimmybchopps/policy); posture renders the per-namespace object they read as
parameters (`paramRef`). Independent of `mesh`.

```yaml
policyExceptions:
  enabled: true                       # false: render nothing (cluster without the CRD)

exceptions:
  prometheus:                         # workload in this namespace, matched by label
    selector: name                    # optional: name | component | instance | app
    policies:
      disallow-host-path:             # the policy's name
        kind: ValidatingAdmissionPolicy   # or MutatingAdmissionPolicy
        reason: "node exporter reads /proc"   # optional
        expires: 2027-03-31           # optional; after this date the entry is left out
      add-default-limits:
        kind: MutatingAdmissionPolicy
        enabled: false                # default true; false keeps the entry but exempts nothing
```

Rendered, inverted to policy -> workloads, entries sorted for stable output:

```yaml
apiVersion: policy.posture.dev/v1alpha1
kind: PolicyExceptions
metadata:
  name: posture-exceptions
  namespace: <release namespace>
  annotations: { posture.dev/rule: exceptions }
spec:
  exceptions:
    - policy: { kind: ValidatingAdmissionPolicy, name: disallow-host-path }
      workloads:
        - matchLabels: { app.kubernetes.io/name: prometheus }
          reason: node exporter reads /proc
          expires: "2027-03-31"
```

- [x] Schema and model: `exceptions` is a map keyed by workload (`nameNotAny`), `policies` a
      map keyed by policy name (a DNS label up to 63 characters, as in the CRD); `kind` is
      `ValidatingAdmissionPolicy` or `MutatingAdmissionPolicy`; `reason` optional (at most
      1024 characters); `enabled` defaults to true; `expires` optional, a `YYYY-MM-DD` date
      (checked to be a real date in the model). Non-empty `exceptions` with
      `policyExceptions.enabled: false` fail (they'd otherwise be silently ignored), and so do
      more than the CRD allows (256 policies, 64 workloads per policy).
- [x] Renderer (`templates/exceptions/`): one `PolicyExceptions` named `posture-exceptions`,
      rendered whenever `policyExceptions.enabled` is true, **even with no exceptions**, so a
      policy's binding can use `parameterNotFoundAction: Deny` and fail closed in namespaces
      without posture (with `Allow` a missing object would skip the policy entirely).
- [x] Expiry: admission CEL has no current-time function, so expiry is applied at render. An
      entry whose `expires` is before today (UTC) is left out of the object and listed in a
      NOTES.txt WARNING; unexpired entries carry `expires` for visibility. An expired exception
      stops exempting at the next render (`helm upgrade`, GitOps resync), not at midnight.
- [x] The CRD is pinned, not copied: the Makefile pins the policy release (`POLICY_VERSION`,
      0.1.0) with the SHA-256 of its CRD and chart package, `make policy-release` fetches and
      verifies them, and `make crd-schema` (`test/crd-schema/`) turns the CRD into the JSON
      schema kubeconform checks every example's `posture-exceptions` against.
- [x] The CEL that reads the object is the policy chart's (its renderer adds an `exempt`
      variable to every policy); it's documented there, in CLAUDE.md "Exceptions", not here.
- [x] Unit tests (`tests/exceptions/`, plus defaults, examples, schema, model-failure, NOTES,
      and model-probe cases): every field, the inversion and sort order, `enabled: false`, the
      empty object, `namePrefix` not applied, the same output under every mesh, the `fail`
      cases, expiry with dates far in the past and future (so tests never flip), and the NOTES
      warnings.
- [x] e2e (`exceptions`, under every mesh), kept minimal: the harness installs the pinned policy
      chart (baked-in policies enforced, optional ones at audit) and `examples/exceptions.yaml`
      in `apps`. Its `posture-exceptions` is accepted by the CRD; `node-agent` (a hostPath,
      excepted from `disallow-host-path` and `restrict-volume-types`) and `legacy` (root,
      excepted from `require-run-as-non-root`, matched by `instance`) are admitted and become
      Ready; `intruder`, node-agent's spec under another name, is refused by
      `disallow-host-path`. Written and statically checked; not yet run.

**Done when** that e2e passes under `MESH=none` and `MESH=istio`, and the existing scenarios
still pass (with the one known egress failure left for phase 5).

Decisions made in phase 4:

- The API group is the policy chart's, `policy.posture.dev/v1alpha1` (the plan said
  `posture.dev`): the policy chart owns the CRD, and its group says so.
- No copy of the CRD in this repo (the plan had `crds-reference/`): the policy chart keeps the
  only copy, and consumers pin a release tag. posture pins by checksum too, so a moved tag
  can't change what's tested. The published package's checksum is the release's
  `SHA256SUMS` (`47d7dd57…`), not a local rehearsal build's.
- `namePrefix` never applies to `posture-exceptions`: the policies' `paramRef` names it
  literally, and a prefixed object would deny every pod in the namespace.
- Under `MESH=none`, run.sh applies the pinned CRD, since every posture install now renders
  the object. Only the `exceptions` scenario installs the policy chart (with
  `--take-ownership`, adopting that CRD) and uninstalls it in a new `teardown` hook
  (`resource-policy: keep` leaves the CRD for later scenarios).
- Under a mesh (`POLICY_FIRST=1`), the policy chart is installed after Calico and before the
  mesh, as the policy chart intends (it's foundational), and stays for the whole run, so the
  mesh's own workloads are admitted against the baseline. Calico comes first: it's the
  cluster substrate, not what posture tests, and its privileged pods would need their own
  exceptions.
- istio-system's exceptions are a posture values file, `test/e2e/values/istio-system.yaml`
  (only `posture-exceptions`: NetworkPolicies off, `mesh: none`), installed before Istio. From
  the 1.31 charts: istiod needs `restrict-seccomp`, and ztunnel needs that plus
  privilege escalation, added capabilities, root, and its hostPath (two policies). istio-cni
  runs in `kube-system` (required on GKE, and Istio's preferred alternative), which the
  policies never evaluate. A refused pod's `FailedCreate` event names the policy; the
  harness prints those events when a pod fails to start.
- Under the policy chart, a namespace's pods are denied until its `posture-exceptions`
  exists, but the baseline checks run before the scenario's posture values apply. So
  `namespace()` installs posture first with `test/e2e/values/exceptions-only.yaml` (only an
  empty `posture-exceptions`), and `install_posture` upgrades that release with
  `--reset-values`. A placeholder applied with kubectl doesn't work: Helm 4's server-side
  apply conflicts with kubectl's field manager once posture changes `spec.exceptions`, and
  `--take-ownership` doesn't settle that. Installing first keeps a single owner, matches the
  real install order (posture is a namespace's first release), needs no test-only Helm flags,
  and exercises the upgrade path users take whenever they change their rules.
- e2e workloads meet the baseline under every mesh (non-root 65532, RuntimeDefault seccomp,
  no privilege escalation, drop ALL), and images are fully qualified, because
  `restrict-image-registries` matches plain prefixes. Its registries list `registry.k8s.io/`,
  `docker.io/curlimages/`, and `docker.io/istio/`.
- e2e covers acceptance and two baked-in policies only, by request. Failing closed in a
  namespace without posture, controller warnings, and `kube-system` are the policy chart's own
  e2e cases and aren't repeated.
- helm-unittest reads an unquoted date in a values file as a timestamp, where Helm keeps it a
  string. Test values and the example quote dates; `make lint` checks the unquoted form with
  real Helm (`tests/values/exceptions-unquoted-date.yaml`).
- Follow-up, outside this phase: when the policy chart serves `v1beta1` (its phase 4), bump
  `POLICY_VERSION` and move the rendered apiVersion.

---

## Phase 5: profiles, egress hostnames, boundary integration (Istio)

`boundary` is a separate chart for the cluster-wide pieces: ingress and egress gateways, the
cluster-wide egress limit, and mesh-wide resources. posture never references or depends on it
and stays namespace-scoped; the two share a few conventions (gateway namespaces, the default
egress gateway's name, the `allowedHosts` shape) and meet only in e2e. Istio only for now; other
meshes follow in phases 6 (Linkerd) and 7 (Cilium).

### 5a. Maps and `enabled` everywhere (breaking, before any release)

- [x] `enabled` (default true) on `ingress.<target>`, `egress.<source>`, every `from`/`to` entry,
      `mtls.exclusions` objects, and `sources` references (object form
      `{ ports, enabled }`, with the ports list still accepted).
- [x] `egress.<source>.destinations` becomes a map (`{ postgres: {}, sso: { enabled: false } }`):
      a list would be replaced wholesale when values are layered.
- [x] Disabled entries render nothing, are still validated, and don't count toward name
      collisions.
- [x] Update the schema, model, examples, snapshots, and every doc that shows the list form.

Decisions made in 5a:

- Validation splits in two. Structural checks (schema, ports, selectors, peer shape, unknown
  source or destination names) run on disabled entries too, so a typo never hides behind
  `enabled: false`. Checks that depend on the surroundings (a destination's required mesh,
  an exclusion needing a mesh or STRICT, STRICT coverage of `cidrs` sources) run only on
  enabled entries: a disabled entry asks for nothing, and profiles (5c) need to carry entries
  a user's setup can't support until they're switched off.
- A disabled rule disables everything under it, and its children are still validated.
- The model lists disabled entries (`disabled: [{ rule }]`), and NOTES.txt shows them under
  "Disabled (enabled: false; validated, not rendered)", not as a warning: switching something
  off is a normal choice.
- `enabled` exists only where a source or destination is used, never on its definition: a
  definition nothing references renders nothing. The schema rejects it there.
- No compatibility for the old `destinations` list: nothing has been released, so the schema
  rejects the list form.
- e2e: `examples/strict.yaml` carries the reverse pair (api -> web) switched off, so the
  `strict` scenario's existing deny of that path also shows disabled rules render nothing.

### 5b. Gateway presets

- [x] `ingress-gateway` source in namespace `ingress-gateway`; `egress-gateway` destination in
      namespace `egress-gateway` (were both `gateway`). No shim (nothing is released): the old
      default is one override away, `sources.ingress-gateway: { namespace: gateway }`.

### 5c. Profiles

- [ ] `profiles.<name>.{enabled, settings}` in the schema, one entry per built-in profile.
- [ ] `templates/_profiles.tpl` and the `posture.values` helper (defaults, then profiles, then
      user values) with the custom deep merge; the model reads it instead of `.Values`.
- [ ] Failures: a profile setting a forbidden key (internal check), two profiles disagreeing on
      a value, a required setting missing.
- [ ] `posture.dev/profile` annotation; NOTES.txt lists profiles, settings, and disabled profile
      entries.
- [ ] `istio-system`: start from `test/e2e/values/istio-system.yaml` (istiod and ztunnel
      exceptions) and add istiod's traffic: 15012 from every namespace, 15017 from
      `apiServerCidrs`, 15014 from the `monitoring` source, egress to `kube-api`. Renders with
      `mesh: none` (installed before Istio) and with `mesh: istio`. The e2e harness switches to
      it.
- [ ] `istio-ingress`: ingress on the `ports` setting from `clientCidrs`; egress to every pod in
      every namespace on 15008 only (meshed backends receive gateway traffic as HBONE, so the
      gateway never needs each application's ports). No exceptions: `boundary` makes the
      gateway pods compliant.
- [ ] `istio-egress`: ingress on 15008 from every namespace; egress outside the cluster on the
      `ports` setting. No exceptions.
- [ ] Unit tests per profile and per failure; snapshots of each profile's output.

### 5d. Egress to hostnames

- [ ] `egress.allowedHosts` as described in CLAUDE.md ("Egress to hostnames"): the reserved key,
      the shared shape, one ServiceEntry per enabled entry, the namespace-wide NetworkPolicy to
      the waypoint, and the non-istio `fail`.
- [ ] Unit tests: every protocol, `hosts` vs `addresses`, the `TCP` + `hosts` failure,
      `gateway` override, the egress-gateway destination namespace override.

### 5e. Boundary integration

- [ ] The e2e harness installs `boundary` after Istio, with posture's gateway profiles in its
      two namespaces first.
- [ ] e2e: an approved host connects through the waypoint; a host `boundary` doesn't list is
      refused at the waypoint; a namespace that didn't list the host can't reach it; a direct
      path that skips the gateway is blocked by NetworkPolicy.
- [ ] Gateway and waypoint pods are admitted with an empty `posture-exceptions` (with the
      policy chart installed).
- [ ] Resolve the remaining accepted failure (`deny prometheus/prometheus -> x.intruder:8081`,
      an egress port limit into a namespace without posture; see "Accepted failures" under 1c).

**Done when** the integration e2e passes under `MESH=istio` with no accepted failures.

---

## Phase 6: Linkerd

- [ ] `mesh: linkerd` joins the schema enum.
- [ ] Linkerd: a `Server` per target port; `AuthorizationPolicy` with `MeshTLSAuthentication`
      (identity `<sa>.<ns>.serviceaccount.identity.linkerd.<trustDomain>`) or
      `NetworkAuthentication` for `cidrs`; mTLS via `Server.spec.accessPolicy`
      (`all-authenticated`, or `all-unauthenticated` for excluded ports).
- [ ] The `egress-gateway` destination `fail`s with an explanation: Linkerd has no egress
      gateway (the destination only exists for Istio's egress waypoint).
- [ ] e2e under `MESH=linkerd` (`run.sh` accepts it), set up like istio: Calico, then the
      policy chart (`POLICY_FIRST`), then the Linkerd namespaces' exceptions from their own
      values file (`test/e2e/values/linkerd.yaml`), then Linkerd.
- [ ] Golden files: one example rendered for istio and linkerd, reviewed side by side.

**Done when** unit tests cover every Linkerd output and its `fail` cases, and
`make e2e MESH=linkerd` passes every scenario that applies to it.

Open questions, settled at the start of the phase:

- linkerd-cni (which could run in `kube-system` like istio-cni, so the proxy-init container
  doesn't need NET_ADMIN) or proxy-init with a posture exception.
- How the existing scenarios map onto Linkerd: there's no HBONE on 15008, and Linkerd
  handles probes its own way.

---

## Phase 7: Cilium

- [ ] `mesh: cilium` joins the schema enum.
- [ ] Cilium: `networkPolicy.provider: cilium` renders `CiliumNetworkPolicy` instead of NetworkPolicy;
      identity rules match `io.cilium.k8s.policy.serviceaccount`; strict mTLS requires Cilium
      mutual authentication, or `fail`s unless the values explicitly accept encryption-only.
- [ ] Cilium as the gateway: Cilium's Gateway API traffic arrives from its shared Envoy with
      the reserved `ingress` identity, not from pods in the `ingress-gateway` namespace. When the
      cluster uses Cilium's gateway, the `ingress-gateway` source renders as
      `fromEntities: [ingress]` (needs `networkPolicy.provider: cilium`).
- [ ] The `egress-gateway` destination `fail`s with an explanation: Cilium's egress gateway
      reroutes at the node, so no hop needs allowing.
- [ ] e2e under `MESH=cilium`: Cilium replaces Calico as the CNI (a second CNI path in the
      k3d setup). The policy chart is installed before Cilium; Cilium in `kube-system` needs
      no exceptions, anywhere else it gets a values file like istio's.
- [ ] Golden files: one example, three meshes, reviewed side by side.

**Done when** unit tests cover every Cilium output and its `fail` cases, and
`make e2e MESH=cilium` passes.

---

## Open questions

1. **An escape hatch for custom resources (deferred, after phase 7).** The generated rules
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

- **Exceptions format (phase 4).** posture renders one `PolicyExceptions`
  (`policy.posture.dev/v1alpha1`) named `posture-exceptions` per namespace, read by native admission
  policies through `paramRef`. Values are `exceptions.<workload>.policies.<policy>` with `kind`,
  optional `reason`, `enabled` (default true) and optional `expires`, matched by label like the
  traffic rules. The object is always rendered (even empty) while `policyExceptions.enabled` is
  true, so policies fail closed (`parameterNotFoundAction: Deny`) where posture isn't
  installed. The CRD is cluster-scoped, so it's owned and installed by the policy chart;
  posture pins a release of it (Makefile `POLICY_VERSION`) for its tests. Expiry is applied at render, since admission
  CEL can't read the time.

- Ports are always required and always numeric. There is no "all ports" form and no named
  ports.
- Under Istio ambient, TCP 15008 is added to every in-cluster NetworkPolicy rule alongside
  its ports; authorization policies list only the user's ports.
- Istio ambient supports port-level PERMISSIVE under a STRICT namespace, and not DISABLE
  (phase 3 reflects this).
- Gateway presets use the mesh-neutral namespaces `ingress-gateway` (the `ingress-gateway`
  source) and `egress-gateway` (the `egress-gateway` destination, Istio only), matching
  `boundary`'s defaults.
- Built-in profiles (mesh and gateway) live in this chart; application profiles are values
  files kept outside it. Profiles may set anything about the namespace except `mesh`,
  `trustDomain`, the troubleshooting switches, and `namePrefix`; conflicting profiles fail.
- Every rule, peer, reference, exclusion, and exception has `enabled`; references to predefined
  destinations are a map. `null` is not a documented way to remove anything.
- Egress to hostnames: `egress.allowedHosts` (namespace-wide, routed through `boundary`'s egress
  waypoint); the cluster-wide limit is enforced by `boundary` at the waypoint.
- The `monitoring` source defaults to namespace `prometheus`, workload `prometheus`. Presets
  assume one namespace per application, named after it.
