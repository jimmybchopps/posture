{{/*
The model: values normalized once into rules that every renderer reads (CLAUDE.md, "One
model, many renderers"). Renderers call:

  {{- $model := include "posture.model" . | fromJson -}}

Shape:

  mesh, namespace, trustDomain, allowSameNamespace
  meshMember: true | false                # false: no authorization, mTLS, or ambient probes
  profiles: [{ name, enabled, settings? }] # every profile listed, in name order
  networkPolicy: { ingress, egress }      # which directions get NetworkPolicies
  authorization: { enabled }              # whether the mesh's authorization policies render
  mtls:                                   # see posture.mtls
    mode: STRICT | PERMISSIVE | inherit
    exclusions: [{ key, name, rule, profile, labels, ports: [int] }]   # allow-plaintext-to-<key>
  exceptions:                             # see posture.exceptions
    enabled: true                         # policyExceptions.enabled: render posture-exceptions
    name: posture-exceptions              # fixed; namePrefix doesn't apply
    policies:                             # sorted by kind, then name; disabled and expired left out
      - { kind, name, workloads: [{ matchLabels, reason?, expires? }] }   # workloads by key
    expired: [{ rule, expires }]          # left out at this render (NOTES warning)
    profiles: [name]                      # profiles that contributed an exception, sorted
  fixed:                                  # fixed objects; a key is absent when not wanted
                                          # (each also has profile: "" or the profile that set
                                          # the key driving it, when the user didn't)
    denyIngress:   { name, rule }         # deny-all-ingress
    denyEgress:    { name, rule }         # deny-all-egress
    sameNamespace: { name, rule }         # allow-same-namespace (allowSameNamespace)
    ambientProbes: { name, rule }         # allow-ingress-from-ambient-probes-to-all (istio)
    mtlsNamespace: { name, rule }         # mtls-<mode> (a mesh, mode not inherit)
    plaintextAll:  { name, rule }         # allow-plaintext-to-all (a mesh, mode PERMISSIVE)
  disabled: [{ rule, profile }]           # entries with enabled: false (theirs or a parent's),
                                          # validated but not rendered; rules, then exclusions
  rules:                                  # one per target and peer pair, in values order
    - name: allow-ingress-from-keycloak-to-grafana
      rule: ingress.grafana.from.keycloak # the posture.dev/rule annotation
      profile: ""                         # the profile that set this entry (posture.dev/profile)
      direction: ingress | egress
      target:                             # the pods in this namespace the rule applies to
        key: grafana
        labels: { app.kubernetes.io/name: grafana }   # {} = every pod
      peer:
        key: keycloak
        inCluster: true
        labels: { ... }                   # {} = every pod     (inCluster only)
        namespace: { scope: same | named | all, name }  #     (inCluster only)
        serviceAccount: ""                #                    (inCluster only)
        cidrs: [{ cidr, except: [] }]     #                    (outside only)
      ports: [{ port, protocol, endPort? }]

Values are the effective values (posture.values, _profiles.tpl): defaults, then enabled
profiles, then the user's values. .Values is read directly only to tell whether the user set a
fixed key a profile also sets (posture.dev/profile on fixed objects), and for namePrefix in
posture.name, which profiles can't set.

The model is mesh-neutral: labels and namespace scopes, never NetworkPolicy fields. It holds
every enabled rule whatever networkPolicy says; each renderer decides what it renders.

Disabled entries (enabled: false on a rule, peer, reference, or exclusion) go through every
structural check (ports, selectors, peer shape, unknown source or destination names), so a
typo never hides behind enabled: false. Checks that depend on the surroundings (a
destination's required mesh, an exclusion needing a mesh or STRICT, STRICT coverage of cidrs
sources) apply only to enabled entries, since a disabled one asks for nothing. Disabled
entries render nothing and aren't in the collision check.

Object names are unique across fixed and rules (posture.checkCollisions), including rules a
renderer skips, so turning a direction back on can't introduce a collision. Disabled entries
aren't checked: only one of two entries with the same name may be on.

Note: fromJson turns numbers into float64. Renderers must use `int` on port numbers before
formatting them with printf.

Helpers here "return" by setting keys on an `out` dict they're given, so values keep their
types; only posture.model itself serializes.

Every fail message has the form "posture: <values path>: <problem>".
*/}}

{{/*
Label key for a selector short name.
*/}}
{{- define "posture.selectorLabel" -}}
{{- $labels := dict "name" "app.kubernetes.io/name" "component" "app.kubernetes.io/component" "instance" "app.kubernetes.io/instance" "app" "app" -}}
{{- $label := get $labels . -}}
{{- if not $label -}}
{{- fail (printf "posture: unknown selector %q; known: app, component, instance, name" .) -}}
{{- end -}}
{{- $label -}}
{{- end -}}

{{/*
Whether a values entry is on: its enabled key, default true. A non-map entry (a ports list)
is always on. Outputs "true" or "false"; compare with eq ... "true".
*/}}
{{- define "posture.enabled" -}}
{{- if and (kindIs "map" .) (hasKey . "enabled") -}}{{- ternary "true" "false" (eq (toString .enabled) "true") -}}{{- else -}}true{{- end -}}
{{- end -}}

{{/*
Normalize a ports list: numbers become { port, protocol: TCP }, protocol defaults to TCP,
endPort must be >= port, exact duplicates are dropped.
Input: dict "rule" <path> "ports" <list> "out" <dict>; sets out.ports.
*/}}
{{- define "posture.normalizePorts" -}}
{{- $rule := .rule -}}
{{- $result := list -}}
{{- $seen := dict -}}
{{- range .ports -}}
  {{- $p := dict -}}
  {{- if kindIs "map" . -}}
    {{- $p = dict "port" (int .port) "protocol" (.protocol | default "TCP") -}}
    {{- if hasKey . "endPort" -}}
      {{- if lt (int .endPort) (int .port) -}}
        {{- fail (printf "posture: %s: endPort %d is lower than port %d" $rule (int .endPort) (int .port)) -}}
      {{- end -}}
      {{- $_ := set $p "endPort" (int .endPort) -}}
    {{- end -}}
  {{- else -}}
    {{- $p = dict "port" (int .) "protocol" "TCP" -}}
  {{- end -}}
  {{- $id := printf "%d-%v/%s" $p.port (get $p "endPort") $p.protocol -}}
  {{- if not (hasKey $seen $id) -}}
    {{- $_ := set $seen $id true -}}
    {{- $result = append $result $p -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "ports" $result -}}
{{- end -}}

{{/*
Normalize a peer from a spec with any of: workload, podSelector, selector, namespace,
serviceAccount, cidrs.
Input: dict "key" <name> "spec" <dict> "defaultSelector" <selector> "out" <dict>; sets out.peer.
*/}}
{{- define "posture.normalizePeer" -}}
{{- $spec := .spec -}}
{{- $peer := dict "key" .key -}}
{{- if hasKey $spec "cidrs" -}}
  {{- $cidrs := list -}}
  {{- range $spec.cidrs -}}
    {{- if kindIs "map" . -}}
      {{- $cidrs = append $cidrs (dict "cidr" .cidr "except" (default (list) .except)) -}}
    {{- else -}}
      {{- $cidrs = append $cidrs (dict "cidr" . "except" (list)) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $peer "inCluster" false -}}
  {{- $_ := set $peer "cidrs" $cidrs -}}
{{- else -}}
  {{- $labels := dict -}}
  {{- if hasKey $spec "podSelector" -}}
    {{- $labels = deepCopy $spec.podSelector -}}
  {{- else if ne $spec.workload "any" -}}
    {{- $selector := $spec.selector | default .defaultSelector -}}
    {{- $labels = dict (include "posture.selectorLabel" $selector) $spec.workload -}}
  {{- end -}}
  {{- $ns := $spec.namespace | default "" -}}
  {{- $namespace := dict "scope" "named" "name" $ns -}}
  {{- if eq $ns "" -}}
    {{- $namespace = dict "scope" "same" "name" "" -}}
  {{- else if eq $ns "any" -}}
    {{- $namespace = dict "scope" "all" "name" "" -}}
  {{- end -}}
  {{- $_ := set $peer "inCluster" true -}}
  {{- $_ := set $peer "labels" $labels -}}
  {{- $_ := set $peer "namespace" $namespace -}}
  {{- $_ := set $peer "serviceAccount" ($spec.serviceAccount | default "") -}}
{{- end -}}
{{- $_ := set .out "peer" $peer -}}
{{- end -}}

{{/*
Merge user sources or destinations over the presets, field by field:
  - setting namespace, workload, or podSelector makes the entry in-cluster: the preset's
    cidrs are dropped
  - setting cidrs makes it outside the cluster: the preset's in-cluster fields are dropped
  - workload and podSelector replace each other
  - one user entry can't set both cidrs and an in-cluster field, or both workload and
    podSelector
Then check every entry is complete.
Input: dict "kind" sources|destinations "presets" <dict> "user" <dict> "out" <dict>; sets
out.definitions.
*/}}
{{- define "posture.resolveDefinitions" -}}
{{- $kind := .kind -}}
{{- $all := dict -}}
{{- range $name, $preset := .presets -}}
  {{- $_ := set $all $name (deepCopy $preset) -}}
{{- end -}}
{{- range $name, $user := .user -}}
  {{- $path := printf "%s.%s" $kind $name -}}
  {{- $user = $user | default dict -}}
  {{- $inCluster := list -}}
  {{- range list "namespace" "workload" "podSelector" -}}
    {{- if hasKey $user . -}}{{- $inCluster = append $inCluster . -}}{{- end -}}
  {{- end -}}
  {{- if and (hasKey $user "cidrs") $inCluster -}}
    {{- fail (printf "posture: %s: cidrs can't be combined with %s; an entry is either outside the cluster (cidrs) or inside it" $path (join ", " $inCluster)) -}}
  {{- end -}}
  {{- if and (hasKey $user "workload") (hasKey $user "podSelector") -}}
    {{- fail (printf "posture: %s: set workload or podSelector, not both" $path) -}}
  {{- end -}}
  {{- if and (hasKey $user "selector") (hasKey $user "podSelector") -}}
    {{- fail (printf "posture: %s: selector applies to workload; with podSelector, write the labels directly" $path) -}}
  {{- end -}}
  {{- $merged := deepCopy (get $all $name | default dict) -}}
  {{- if hasKey $user "cidrs" -}}
    {{- $merged = omit $merged "namespace" "workload" "selector" "podSelector" "serviceAccount" -}}
  {{- else if $inCluster -}}
    {{- $merged = omit $merged "cidrs" -}}
  {{- end -}}
  {{- if hasKey $user "workload" -}}
    {{- $merged = omit $merged "podSelector" -}}
  {{- else if hasKey $user "podSelector" -}}
    {{- $merged = omit $merged "workload" "selector" -}}
  {{- end -}}
  {{- range $field, $value := $user -}}
    {{- $_ := set $merged $field $value -}}
  {{- end -}}
  {{- $_ := set $all $name $merged -}}
{{- end -}}
{{- range $name, $def := $all -}}
  {{- $path := printf "%s.%s" $kind $name -}}
  {{- if not (or (hasKey $def "cidrs") (hasKey $def "workload") (hasKey $def "podSelector")) -}}
    {{- fail (printf "posture: %s: set workload (any for every pod in the namespace), podSelector, or cidrs" $path) -}}
  {{- end -}}
  {{- if and (eq $kind "destinations") (not $def.ports) -}}
    {{- fail (printf "posture: %s: a destination needs ports" $path) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "definitions" $all -}}
{{- end -}}

{{/*
Look up a source or destination by name, failing with the list of known names.
Input: dict "kind" source|destination "name" <name> "definitions" <dict> "rule" <path>
       "mesh" <mesh> "enabled" <bool> "out" <dict>; sets out.definition. The required-mesh
       check applies only when enabled.
*/}}
{{- define "posture.lookupDefinition" -}}
{{- $def := get .definitions .name -}}
{{- if not $def -}}
  {{- fail (printf "posture: %s: unknown %s %q; known: %s" .rule .kind .name (keys .definitions | sortAlpha | join ", ")) -}}
{{- end -}}
{{- with and .enabled $def.requiresMesh -}}
  {{- if ne .mesh $.mesh -}}
    {{- fail (printf "posture: %s: the %s %q needs mesh: %s (%s); mesh is %s" $.rule $.kind $.name .mesh .reason $.mesh) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "definition" $def -}}
{{- end -}}

{{/*
Build one rule and append it to acc.rules, or, when it isn't enabled, validate it the same
way and append { rule } to acc.disabled.
Input: dict "root" "acc" "direction" "rule" "target" (dict key labels) "peerKey" "peerSpec"
       "peerToken" "defaultSelector" "ports" "enabled"
*/}}
{{- define "posture.addRule" -}}
{{- $peerOut := dict -}}
{{- $_ := include "posture.normalizePeer" (dict "key" .peerKey "spec" .peerSpec "defaultSelector" .defaultSelector "out" $peerOut) -}}
{{- $portsOut := dict -}}
{{- $_ := include "posture.normalizePorts" (dict "rule" .rule "ports" .ports "out" $portsOut) -}}
{{- $targetToken := include "posture.targetToken" .target.key -}}
{{- $source := ternary .peerToken $targetToken (eq .direction "ingress") -}}
{{- $destination := ternary $targetToken .peerToken (eq .direction "ingress") -}}
{{- $name := include "posture.name" (dict "root" .root "rule" .rule "direction" .direction "source" $source "destination" $destination) -}}
{{- if .enabled -}}
  {{- $r := dict "name" $name "rule" .rule "direction" .direction "target" .target "peer" $peerOut.peer "ports" $portsOut.ports -}}
  {{- $_ := set .acc "rules" (append .acc.rules $r) -}}
{{- else -}}
  {{- $_ := set .acc "disabled" (append .acc.disabled (dict "rule" .rule)) -}}
{{- end -}}
{{- end -}}

{{/*
The target of a rule: the pods in this namespace with that workload label, or every pod.
Input: dict "key" <key> "selector" <selector>; outputs JSON.
*/}}
{{- define "posture.target" -}}
{{- $labels := dict -}}
{{- if ne .key "any" -}}
  {{- $labels = dict (include "posture.selectorLabel" .selector) .key -}}
{{- end -}}
{{- toJson (dict "key" .key "labels" $labels) -}}
{{- end -}}

{{/*
Peers from a from/to map. Keys name workloads ("any" = every pod) or, for cidrs entries,
just name the entry.
Input: dict "root" "acc" "direction" "path" "target" "entries" "defaultSelector" "enabled"
(the rule's own enabled; each entry is on only if the rule is too)
*/}}
{{- define "posture.addPeerRules" -}}
{{- $ctx := . -}}
{{- range $key, $entry := .entries -}}
  {{- $path := printf "%s.%s" $ctx.path $key -}}
  {{- if not $entry.ports -}}
    {{- fail (printf "posture: %s: ports are required (a non-empty list)" $path) -}}
  {{- end -}}
  {{- if hasKey $entry "cidrs" -}}
    {{- range list "namespace" "selector" "serviceAccount" -}}
      {{- if hasKey $entry . -}}
        {{- fail (printf "posture: %s: cidrs can't be combined with %s; an entry is either outside the cluster (cidrs) or inside it" $path .) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $on := and $ctx.enabled (eq (include "posture.enabled" $entry) "true") -}}
  {{- $spec := omit $entry "ports" "enabled" -}}
  {{- if not (hasKey $spec "cidrs") -}}
    {{- $_ := set $spec "workload" $key -}}
  {{- end -}}
  {{- $token := include "posture.peerToken" (dict "key" $key "namespace" ($entry.namespace | default "")) -}}
  {{- $_ := include "posture.addRule" (dict "root" $ctx.root "acc" $ctx.acc "direction" $ctx.direction "rule" (printf "%s.%s" $ctx.path $key) "target" $ctx.target "peerKey" $key "peerSpec" $spec "peerToken" $token "defaultSelector" $ctx.defaultSelector "ports" $entry.ports "enabled" $on) -}}
{{- end -}}
{{- end -}}

{{- define "posture.model" -}}
{{- $root := . -}}
{{- $valuesOut := dict -}}
{{- $_ := include "posture.values" (dict "root" . "out" $valuesOut) -}}
{{- $v := $valuesOut.values -}}
{{- $origins := $valuesOut.origins -}}
{{- $mesh := $v.mesh -}}
{{- $member := $v.meshMember -}}

{{- /* Istio's root namespace: namespace-wide authorization and mTLS objects there apply to the
whole mesh. A custom root namespace (meshConfig.rootNamespace) isn't detected. */ -}}
{{- if and (eq $mesh "istio") $member (eq .Release.Namespace "istio-system") (or $v.authorization.enabled (ne $v.mtls.mode "inherit")) -}}
  {{- fail "posture: istio-system is Istio's root namespace, where namespace-wide AuthorizationPolicies and PeerAuthentications apply to the whole mesh (posture's deny-all-ingress would deny every meshed workload); enable profiles.istio-system, or set meshMember: false" -}}
{{- end -}}

{{- /* The profile behind a fixed key, if a profile set it and the user didn't. */ -}}
{{- $userMtls := $root.Values.mtls | default dict -}}
{{- $fixedProfile := dict -}}
{{- range $key, $userSet := dict "allowSameNamespace" (hasKey $root.Values "allowSameNamespace") "allowDNS" (hasKey $root.Values "allowDNS") "mtls.mode" (hasKey $userMtls "mode") -}}
  {{- $_ := set $fixedProfile $key (ternary "" (get $origins $key | default "") $userSet) -}}
{{- end -}}

{{- $out := dict -}}
{{- $_ := include "posture.resolveDefinitions" (dict "kind" "sources" "presets" (include "posture.presets.sources" . | fromYaml) "user" $v.sources "out" $out) -}}
{{- $sources := $out.definitions -}}
{{- $out = dict -}}
{{- $_ := include "posture.resolveDefinitions" (dict "kind" "destinations" "presets" (include "posture.presets.destinations" . | fromYaml) "user" $v.destinations "out" $out) -}}
{{- $destinations := $out.definitions -}}

{{- $acc := dict "rules" (list) "disabled" (list) -}}

{{- range $key, $rule := $v.ingress -}}
  {{- $path := printf "ingress.%s" $key -}}
  {{- if not (or $rule.from $rule.sources) -}}
    {{- fail (printf "posture: %s: needs from or sources" $path) -}}
  {{- end -}}
  {{- $ruleOn := eq (include "posture.enabled" $rule) "true" -}}
  {{- $selector := $rule.selector | default "name" -}}
  {{- $target := include "posture.target" (dict "key" $key "selector" $selector) | fromJson -}}
  {{- $_ := include "posture.addPeerRules" (dict "root" $root "acc" $acc "direction" "ingress" "path" (printf "%s.from" $path) "target" $target "entries" $rule.from "defaultSelector" $selector "enabled" $ruleOn) -}}
  {{- range $name, $ref := $rule.sources -}}
    {{- $rulePath := printf "%s.sources.%s" $path $name -}}
    {{- $on := and $ruleOn (eq (include "posture.enabled" $ref) "true") -}}
    {{- $ports := $ref -}}
    {{- if kindIs "map" $ref -}}{{- $ports = $ref.ports -}}{{- end -}}
    {{- if not $ports -}}
      {{- fail (printf "posture: %s: ports are required (the ports on %s this source reaches)" $rulePath $key) -}}
    {{- end -}}
    {{- $found := dict -}}
    {{- $_ := include "posture.lookupDefinition" (dict "kind" "source" "name" $name "definitions" $sources "rule" $rulePath "mesh" $mesh "enabled" $on "out" $found) -}}
    {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "ingress" "rule" $rulePath "target" $target "peerKey" $name "peerSpec" $found.definition "peerToken" $name "defaultSelector" "name" "ports" $ports "enabled" $on) -}}
  {{- end -}}
{{- end -}}

{{- range $key, $rule := $v.egress -}}
  {{- $path := printf "egress.%s" $key -}}
  {{- if not (or $rule.to $rule.destinations) -}}
    {{- fail (printf "posture: %s: needs to or destinations" $path) -}}
  {{- end -}}
  {{- $ruleOn := eq (include "posture.enabled" $rule) "true" -}}
  {{- $selector := $rule.selector | default "name" -}}
  {{- $target := include "posture.target" (dict "key" $key "selector" $selector) | fromJson -}}
  {{- $_ := include "posture.addPeerRules" (dict "root" $root "acc" $acc "direction" "egress" "path" (printf "%s.to" $path) "target" $target "entries" $rule.to "defaultSelector" $selector "enabled" $ruleOn) -}}
  {{- range $name, $ref := ($rule.destinations | default dict) -}}
    {{- $rulePath := printf "%s.destinations.%s" $path $name -}}
    {{- $on := and $ruleOn (eq (include "posture.enabled" ($ref | default dict)) "true") -}}
    {{- $found := dict -}}
    {{- $_ := include "posture.lookupDefinition" (dict "kind" "destination" "name" $name "definitions" $destinations "rule" $rulePath "mesh" $mesh "enabled" $on "out" $found) -}}
    {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "egress" "rule" $rulePath "target" $target "peerKey" $name "peerSpec" $found.definition "peerToken" $name "defaultSelector" "name" "ports" $found.definition.ports "enabled" $on) -}}
  {{- end -}}
{{- end -}}

{{- if $v.allowDNS -}}
  {{- $found := dict -}}
  {{- $_ := include "posture.lookupDefinition" (dict "kind" "destination" "name" "dns" "definitions" $destinations "rule" "allowDNS" "mesh" $mesh "enabled" true "out" $found) -}}
  {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "egress" "rule" "allowDNS" "target" (dict "key" "any" "labels" (dict)) "peerKey" "dns" "peerSpec" $found.definition "peerToken" "dns" "defaultSelector" "name" "ports" $found.definition.ports "enabled" true) -}}
{{- end -}}

{{- $fixed := dict
  "denyIngress" (dict "name" (include "posture.name" (dict "root" $root "rule" "networkPolicy.ingress" "fixed" "deny-all-ingress")) "rule" "networkPolicy.ingress" "profile" "")
  "denyEgress" (dict "name" (include "posture.name" (dict "root" $root "rule" "networkPolicy.egress" "fixed" "deny-all-egress")) "rule" "networkPolicy.egress" "profile" "") -}}
{{- if $v.allowSameNamespace -}}
  {{- $_ := set $fixed "sameNamespace" (dict "name" (include "posture.name" (dict "root" $root "rule" "allowSameNamespace" "fixed" "allow-same-namespace")) "rule" "allowSameNamespace" "profile" $fixedProfile.allowSameNamespace) -}}
{{- end -}}
{{- if and (eq $mesh "istio") $member -}}
  {{- $_ := set $fixed "ambientProbes" (dict "name" (include "posture.name" (dict "root" $root "rule" "mesh" "fixed" "allow-ingress-from-ambient-probes-to-all")) "rule" "mesh" "profile" "") -}}
{{- end -}}

{{- $mtlsOut := dict -}}
{{- $_ := include "posture.mtls" (dict "root" $root "values" $v "mesh" $mesh "member" $member "origins" $origins "modeProfile" (get $fixedProfile "mtls.mode") "rules" $acc.rules "fixed" $fixed "out" $mtlsOut) -}}

{{- $_ := include "posture.checkCollisions" (dict "fixed" $fixed "rules" (concat $acc.rules $mtlsOut.mtls.exclusions)) -}}

{{- $exceptionsOut := dict -}}
{{- $_ := include "posture.exceptions" (dict "root" $root "values" $v "origins" $origins "out" $exceptionsOut) -}}

{{- /* Which profile each rule and disabled entry came from (posture.dev/profile). */ -}}
{{- range $acc.rules -}}
  {{- $_ := set . "profile" (ternary (get $fixedProfile "allowDNS") (get $origins .rule | default "") (eq .rule "allowDNS")) -}}
{{- end -}}
{{- $disabled := $acc.disabled -}}
{{- range $mtlsOut.mtls.disabled -}}{{- $disabled = append $disabled . -}}{{- end -}}
{{- range $disabled -}}
  {{- $_ := set . "profile" (get $origins .rule | default "") -}}
{{- end -}}

{{- toJson (dict
  "mesh" $mesh
  "namespace" .Release.Namespace
  "trustDomain" $v.trustDomain
  "networkPolicy" (dict "ingress" $v.networkPolicy.ingress "egress" $v.networkPolicy.egress)
  "authorization" (dict "enabled" $v.authorization.enabled)
  "mtls" (omit $mtlsOut.mtls "disabled")
  "exceptions" $exceptionsOut.exceptions
  "allowSameNamespace" $v.allowSameNamespace
  "meshMember" $member
  "profiles" $valuesOut.profiles
  "fixed" $fixed
  "rules" $acc.rules
  "disabled" $disabled) -}}
{{- end -}}

{{/*
mTLS: the mode, the exclusions, and the fixed objects they need. With mesh: none nothing is
managed, but exclusions fail (no mesh can provide them). Exclusions are only valid with
STRICT. Under STRICT, a cidrs source (outside the cluster, never mTLS) must target excluded
ports, or nothing could ever reach them.
Adds fixed.mtlsNamespace (mtls-<mode>, unless inherit) and fixed.plaintextAll
(allow-plaintext-to-all, PERMISSIVE) when a mesh is set.
Disabled exclusions (object form, enabled: false) are validated like the rest but skip the
mesh and mode checks, render nothing, and don't cover any port.
With meshMember false the namespace isn't in the mesh data plane: nothing is managed, and
enabled exclusions fail, as with mesh: none.
Input: dict "root" "values" (effective) "mesh" "member" "origins" "modeProfile" "rules" "fixed"
"out"; sets out.mtls:
  { mode, exclusions: [{ key, name, rule, profile, labels, ports: [int] }], disabled: [{ rule }] }
  (out.mtls.disabled is merged into the model's disabled, not output under mtls)
*/}}
{{- define "posture.mtls" -}}
{{- $root := .root -}}
{{- $v := .values -}}
{{- $mode := $v.mtls.mode -}}
{{- $exclusions := list -}}
{{- $disabled := list -}}
{{- range $key, $entry := ($v.mtls.exclusions | default dict) -}}
  {{- $path := printf "mtls.exclusions.%s" $key -}}
  {{- $on := eq (include "posture.enabled" $entry) "true" -}}
  {{- if not $on -}}
  {{- else if eq $.mesh "none" -}}
    {{- fail (printf "posture: %s: exclusions need a mesh to accept plaintext beside mTLS; mesh is none" $path) -}}
  {{- else if not $.member -}}
    {{- fail (printf "posture: %s: exclusions need this namespace in the mesh data plane; meshMember is false" $path) -}}
  {{- else if ne $mode "STRICT" -}}
    {{- fail (printf "posture: %s: exclusions only apply with mtls.mode STRICT; mode is %s (%s)" $path $mode (ternary "every port already accepts plaintext" "the chart isn't managing mTLS" (eq $mode "PERMISSIVE"))) -}}
  {{- end -}}
  {{- $ports := $entry -}}
  {{- $selector := "name" -}}
  {{- if kindIs "map" $entry -}}
    {{- $ports = $entry.ports -}}
    {{- $selector = $entry.selector | default "name" -}}
  {{- end -}}
  {{- if not $ports -}}
    {{- fail (printf "posture: %s: ports are required (a non-empty list)" $path) -}}
  {{- end -}}
  {{- $intPorts := list -}}
  {{- range $ports -}}{{- $intPorts = append $intPorts (int .) -}}{{- end -}}
  {{- $name := include "posture.name" (dict "root" $root "rule" $path "fixed" (printf "allow-plaintext-to-%s" $key)) -}}
  {{- $labels := dict (include "posture.selectorLabel" $selector) $key -}}
  {{- if $on -}}
    {{- $exclusions = append $exclusions (dict "key" $key "name" $name "rule" $path "profile" (get $.origins $path | default "") "labels" $labels "ports" ($intPorts | uniq)) -}}
  {{- else -}}
    {{- $disabled = append $disabled (dict "rule" $path) -}}
  {{- end -}}
{{- end -}}
{{- if and (ne .mesh "none") .member -}}
  {{- if ne $mode "inherit" -}}
    {{- $_ := set .fixed "mtlsNamespace" (dict "name" (include "posture.name" (dict "root" $root "rule" "mtls.mode" "fixed" (printf "mtls-%s" (lower $mode)))) "rule" "mtls.mode" "profile" .modeProfile) -}}
  {{- end -}}
  {{- if eq $mode "PERMISSIVE" -}}
    {{- $_ := set .fixed "plaintextAll" (dict "name" (include "posture.name" (dict "root" $root "rule" "mtls.mode" "fixed" "allow-plaintext-to-all")) "rule" "mtls.mode" "profile" .modeProfile) -}}
  {{- end -}}
  {{- if eq $mode "STRICT" -}}
    {{- range $rule := .rules -}}
      {{- if and (eq $rule.direction "ingress") (not $rule.peer.inCluster) -}}
        {{- $covered := list -}}
        {{- range $exclusions -}}
          {{- if eq (toJson .labels) (toJson $rule.target.labels) -}}{{- $covered = concat $covered .ports -}}{{- end -}}
        {{- end -}}
        {{- range $rule.ports -}}
          {{- if eq .protocol "TCP" -}}
            {{- $first := int .port -}}
            {{- $last := ternary (int (get . "endPort")) $first (hasKey . "endPort") -}}
            {{- range $p := untilStep $first (int (add $last 1)) 1 -}}
              {{- if not (has $p $covered) -}}
                {{- if not $rule.target.labels -}}
                  {{- fail (printf "posture: %s: port %d is reached from outside the cluster (cidrs), which is never mTLS, but mtls.mode is STRICT and the target is every pod (any), which exclusions can't name; use mtls.mode PERMISSIVE" $rule.rule $p) -}}
                {{- end -}}
                {{- fail (printf "posture: %s: port %d is reached from outside the cluster (cidrs), which is never mTLS, but mtls.mode is STRICT; add it under mtls.exclusions.%s, or use mtls.mode PERMISSIVE" $rule.rule $p $rule.target.key) -}}
              {{- end -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "mtls" (dict "mode" $mode "exclusions" $exclusions "disabled" $disabled) -}}
{{- end -}}

{{/*
Admission-policy exceptions, inverted from workload -> policies to policy -> workloads for the
PolicyExceptions object. Independent of mesh. Entries with enabled: false are left out; so
are entries whose expires date is before today (UTC), which are listed in expired for
NOTES.txt. Today is the render date, the only input from outside the values, and it can only
remove an exception. The object name is fixed (the policies' paramRef names it), so
namePrefix doesn't apply and it can't collide with the allow- and deny- names.
Limits are the CRD's (policy.posture.dev_policyexceptions.yaml): 256 policies, 64 workloads
per policy.
Input: dict "root" "values" (effective) "origins" "out"; sets out.exceptions (see the model's
shape above).
*/}}
{{- define "posture.exceptions" -}}
{{- $v := .values -}}
{{- $origins := .origins -}}
{{- $fromProfiles := dict -}}
{{- $enabled := $v.policyExceptions.enabled -}}
{{- $entries := $v.exceptions | default dict -}}
{{- if and $entries (not $enabled) -}}
  {{- fail (printf "posture: exceptions: %s set, but policyExceptions.enabled is false, so no posture-exceptions object would carry them; enable it, or remove the exceptions" (keys $entries | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $today := dateInZone "2006-01-02" now "UTC" -}}
{{- $byPolicy := dict -}}
{{- $expired := list -}}
{{- range $workload, $entry := $entries -}}
  {{- $labels := dict (include "posture.selectorLabel" ($entry.selector | default "name")) $workload -}}
  {{- if not $entry.policies -}}
    {{- fail (printf "posture: exceptions.%s: policies are required" $workload) -}}
  {{- end -}}
  {{- range $policy, $p := $entry.policies -}}
    {{- $path := printf "exceptions.%s.policies.%s" $workload $policy -}}
    {{- if not $p.kind -}}
      {{- fail (printf "posture: %s: kind is required (ValidatingAdmissionPolicy or MutatingAdmissionPolicy)" $path) -}}
    {{- end -}}
    {{- $on := ternary $p.enabled true (hasKey $p "enabled") -}}
    {{- $expires := "" -}}
    {{- if hasKey $p "expires" -}}
      {{- $expires = toString $p.expires -}}
      {{- if ne (toDate "2006-01-02" $expires | date "2006-01-02") $expires -}}
        {{- fail (printf "posture: %s.expires: %q isn't a valid date (YYYY-MM-DD)" $path $expires) -}}
      {{- end -}}
    {{- end -}}
    {{- if not $on -}}
    {{- else if and $expires (lt $expires $today) -}}
      {{- $expired = append $expired (dict "rule" $path "expires" $expires) -}}
    {{- else -}}
      {{- with get $origins $path -}}{{- $_ := set $fromProfiles . true -}}{{- end -}}
      {{- $w := dict "matchLabels" $labels -}}
      {{- with $p.reason -}}{{- $_ := set $w "reason" . -}}{{- end -}}
      {{- with $expires -}}{{- $_ := set $w "expires" . -}}{{- end -}}
      {{- $key := printf "%s/%s" $p.kind $policy -}}
      {{- $current := get $byPolicy $key | default (dict "kind" $p.kind "name" $policy "workloads" (list)) -}}
      {{- $_ := set $current "workloads" (append $current.workloads $w) -}}
      {{- $_ := set $byPolicy $key $current -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $policies := list -}}
{{- range $key := keys $byPolicy | sortAlpha -}}
  {{- $p := get $byPolicy $key -}}
  {{- if gt (len $p.workloads) 64 -}}
    {{- fail (printf "posture: exceptions: %s %s is excepted for %d workloads; the PolicyExceptions CRD allows at most 64 per policy" $p.kind $p.name (len $p.workloads)) -}}
  {{- end -}}
  {{- $policies = append $policies $p -}}
{{- end -}}
{{- if gt (len $policies) 256 -}}
  {{- fail (printf "posture: exceptions: %d policies are excepted; the PolicyExceptions CRD allows at most 256" (len $policies)) -}}
{{- end -}}
{{- $_ := set .out "exceptions" (dict "enabled" $enabled "name" "posture-exceptions" "policies" $policies "expired" $expired "profiles" (keys $fromProfiles | sortAlpha)) -}}
{{- end -}}

{{/*
Fail if two objects would get the same name, naming both values paths.
Fixed objects are checked first, so a rule that collides with one is reported against it.
Input: dict "fixed" <dict of {name, rule}> "rules" <list>
*/}}
{{- define "posture.checkCollisions" -}}
{{- $seen := dict -}}
{{- $all := list -}}
{{- range $key := list "denyIngress" "denyEgress" "sameNamespace" "ambientProbes" "mtlsNamespace" "plaintextAll" -}}
  {{- with get $.fixed $key -}}{{- $all = append $all . -}}{{- end -}}
{{- end -}}
{{- range .rules -}}{{- $all = append $all . -}}{{- end -}}
{{- range $all -}}
  {{- if hasKey $seen .name -}}
    {{- fail (printf "posture: %s and %s both produce the object name %q; rename or remove one" (get $seen .name) .rule .name) -}}
  {{- end -}}
  {{- $_ := set $seen .name .rule -}}
{{- end -}}
{{- end -}}
