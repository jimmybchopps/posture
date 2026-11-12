{{/*
The model: values normalized once into rules that every renderer reads (CLAUDE.md, "One
model, many renderers"). Renderers call:

  {{- $model := include "posture.model" . | fromJson -}}

Shape:

  mesh, namespace, trustDomain, allowSameNamespace
  networkPolicy: { ingress, egress }      # which directions get NetworkPolicies
  authorization: { enabled }              # whether the mesh's authorization policies render
  mtls:                                   # see posture.mtls
    mode: STRICT | PERMISSIVE | inherit
    exclusions: [{ key, name, rule, labels, ports: [int] }]   # allow-plaintext-to-<key>
  exceptions:                             # see posture.exceptions
    enabled: true                         # policyExceptions.enabled: render posture-exceptions
    name: posture-exceptions              # fixed; namePrefix doesn't apply
    policies:                             # sorted by kind, then name; disabled and expired left out
      - { kind, name, workloads: [{ matchLabels, reason?, expires? }] }   # workloads by key
    expired: [{ rule, expires }]          # left out at this render (NOTES warning)
  fixed:                                  # fixed objects; a key is absent when not wanted
    denyIngress:   { name, rule }         # deny-all-ingress
    denyEgress:    { name, rule }         # deny-all-egress
    sameNamespace: { name, rule }         # allow-same-namespace (allowSameNamespace)
    ambientProbes: { name, rule }         # allow-ingress-from-ambient-probes-to-all (istio)
    mtlsNamespace: { name, rule }         # mtls-<mode> (a mesh, mode not inherit)
    plaintextAll:  { name, rule }         # allow-plaintext-to-all (a mesh, mode PERMISSIVE)
  rules:                                  # one per target and peer pair, in values order
    - name: allow-ingress-from-keycloak-to-grafana
      rule: ingress.grafana.from.keycloak # the posture.dev/rule annotation
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

The model is mesh-neutral: labels and namespace scopes, never NetworkPolicy fields. It holds
every rule whatever networkPolicy says; each renderer decides what it renders.

Object names are unique across fixed and rules (posture.checkCollisions), including rules a
renderer skips, so turning a direction back on can't introduce a collision.

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
       "mesh" <mesh> "out" <dict>; sets out.definition.
*/}}
{{- define "posture.lookupDefinition" -}}
{{- $def := get .definitions .name -}}
{{- if not $def -}}
  {{- fail (printf "posture: %s: unknown %s %q; known: %s" .rule .kind .name (keys .definitions | sortAlpha | join ", ")) -}}
{{- end -}}
{{- with $def.requiresMesh -}}
  {{- if ne .mesh $.mesh -}}
    {{- fail (printf "posture: %s: the %s %q needs mesh: %s (%s); mesh is %s" $.rule $.kind $.name .mesh .reason $.mesh) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "definition" $def -}}
{{- end -}}

{{/*
Build one rule and append it to acc.rules.
Input: dict "root" "acc" "direction" "rule" "target" (dict key labels) "peerKey" "peerSpec"
       "peerToken" "defaultSelector" "ports"
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
{{- $r := dict "name" $name "rule" .rule "direction" .direction "target" .target "peer" $peerOut.peer "ports" $portsOut.ports -}}
{{- $_ := set .acc "rules" (append .acc.rules $r) -}}
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
Input: dict "root" "acc" "direction" "path" "target" "entries" "defaultSelector"
*/}}
{{- define "posture.addPeerRules" -}}
{{- $ctx := . -}}
{{- range $key, $entry := .entries -}}
  {{- $spec := omit $entry "ports" -}}
  {{- if not (hasKey $spec "cidrs") -}}
    {{- $_ := set $spec "workload" $key -}}
  {{- end -}}
  {{- $token := include "posture.peerToken" (dict "key" $key "namespace" ($entry.namespace | default "")) -}}
  {{- $_ := include "posture.addRule" (dict "root" $ctx.root "acc" $ctx.acc "direction" $ctx.direction "rule" (printf "%s.%s" $ctx.path $key) "target" $ctx.target "peerKey" $key "peerSpec" $spec "peerToken" $token "defaultSelector" $ctx.defaultSelector "ports" $entry.ports) -}}
{{- end -}}
{{- end -}}

{{- define "posture.model" -}}
{{- $root := . -}}
{{- $v := .Values -}}
{{- $mesh := $v.mesh -}}

{{- $out := dict -}}
{{- $_ := include "posture.resolveDefinitions" (dict "kind" "sources" "presets" (include "posture.presets.sources" . | fromYaml) "user" $v.sources "out" $out) -}}
{{- $sources := $out.definitions -}}
{{- $out = dict -}}
{{- $_ := include "posture.resolveDefinitions" (dict "kind" "destinations" "presets" (include "posture.presets.destinations" . | fromYaml) "user" $v.destinations "out" $out) -}}
{{- $destinations := $out.definitions -}}

{{- $acc := dict "rules" (list) -}}

{{- range $key, $rule := $v.ingress -}}
  {{- $path := printf "ingress.%s" $key -}}
  {{- $selector := $rule.selector | default "name" -}}
  {{- $target := include "posture.target" (dict "key" $key "selector" $selector) | fromJson -}}
  {{- $_ := include "posture.addPeerRules" (dict "root" $root "acc" $acc "direction" "ingress" "path" (printf "%s.from" $path) "target" $target "entries" $rule.from "defaultSelector" $selector) -}}
  {{- range $name, $ports := $rule.sources -}}
    {{- $rulePath := printf "%s.sources.%s" $path $name -}}
    {{- $found := dict -}}
    {{- $_ := include "posture.lookupDefinition" (dict "kind" "source" "name" $name "definitions" $sources "rule" $rulePath "mesh" $mesh "out" $found) -}}
    {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "ingress" "rule" $rulePath "target" $target "peerKey" $name "peerSpec" $found.definition "peerToken" $name "defaultSelector" "name" "ports" $ports) -}}
  {{- end -}}
{{- end -}}

{{- range $key, $rule := $v.egress -}}
  {{- $path := printf "egress.%s" $key -}}
  {{- $selector := $rule.selector | default "name" -}}
  {{- $target := include "posture.target" (dict "key" $key "selector" $selector) | fromJson -}}
  {{- $_ := include "posture.addPeerRules" (dict "root" $root "acc" $acc "direction" "egress" "path" (printf "%s.to" $path) "target" $target "entries" $rule.to "defaultSelector" $selector) -}}
  {{- range $name := ($rule.destinations | default list | uniq) -}}
    {{- $rulePath := printf "%s.destinations.%s" $path $name -}}
    {{- $found := dict -}}
    {{- $_ := include "posture.lookupDefinition" (dict "kind" "destination" "name" $name "definitions" $destinations "rule" $rulePath "mesh" $mesh "out" $found) -}}
    {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "egress" "rule" $rulePath "target" $target "peerKey" $name "peerSpec" $found.definition "peerToken" $name "defaultSelector" "name" "ports" $found.definition.ports) -}}
  {{- end -}}
{{- end -}}

{{- if $v.allowDNS -}}
  {{- $found := dict -}}
  {{- $_ := include "posture.lookupDefinition" (dict "kind" "destination" "name" "dns" "definitions" $destinations "rule" "allowDNS" "mesh" $mesh "out" $found) -}}
  {{- $_ := include "posture.addRule" (dict "root" $root "acc" $acc "direction" "egress" "rule" "allowDNS" "target" (dict "key" "any" "labels" (dict)) "peerKey" "dns" "peerSpec" $found.definition "peerToken" "dns" "defaultSelector" "name" "ports" $found.definition.ports) -}}
{{- end -}}

{{- $fixed := dict
  "denyIngress" (dict "name" (include "posture.name" (dict "root" $root "rule" "networkPolicy.ingress" "fixed" "deny-all-ingress")) "rule" "networkPolicy.ingress")
  "denyEgress" (dict "name" (include "posture.name" (dict "root" $root "rule" "networkPolicy.egress" "fixed" "deny-all-egress")) "rule" "networkPolicy.egress") -}}
{{- if $v.allowSameNamespace -}}
  {{- $_ := set $fixed "sameNamespace" (dict "name" (include "posture.name" (dict "root" $root "rule" "allowSameNamespace" "fixed" "allow-same-namespace")) "rule" "allowSameNamespace") -}}
{{- end -}}
{{- if eq $mesh "istio" -}}
  {{- $_ := set $fixed "ambientProbes" (dict "name" (include "posture.name" (dict "root" $root "rule" "mesh" "fixed" "allow-ingress-from-ambient-probes-to-all")) "rule" "mesh") -}}
{{- end -}}

{{- $mtlsOut := dict -}}
{{- $_ := include "posture.mtls" (dict "root" $root "mesh" $mesh "rules" $acc.rules "fixed" $fixed "out" $mtlsOut) -}}

{{- $_ := include "posture.checkCollisions" (dict "fixed" $fixed "rules" (concat $acc.rules $mtlsOut.mtls.exclusions)) -}}

{{- $exceptionsOut := dict -}}
{{- $_ := include "posture.exceptions" (dict "root" $root "out" $exceptionsOut) -}}

{{- toJson (dict
  "mesh" $mesh
  "namespace" .Release.Namespace
  "trustDomain" $v.trustDomain
  "networkPolicy" (dict "ingress" $v.networkPolicy.ingress "egress" $v.networkPolicy.egress)
  "authorization" (dict "enabled" $v.authorization.enabled)
  "mtls" $mtlsOut.mtls
  "exceptions" $exceptionsOut.exceptions
  "allowSameNamespace" $v.allowSameNamespace
  "fixed" $fixed
  "rules" $acc.rules) -}}
{{- end -}}

{{/*
mTLS: the mode, the exclusions, and the fixed objects they need. With mesh: none nothing is
managed, but exclusions fail (no mesh can provide them). Exclusions are only valid with
STRICT. Under STRICT, a cidrs source (outside the cluster, never mTLS) must target excluded
ports, or nothing could ever reach them.
Adds fixed.mtlsNamespace (mtls-<mode>, unless inherit) and fixed.plaintextAll
(allow-plaintext-to-all, PERMISSIVE) when a mesh is set.
Input: dict "root" "mesh" "rules" "fixed" "out"; sets out.mtls:
  { mode, exclusions: [{ key, name, rule, labels, ports: [int] }] }
*/}}
{{- define "posture.mtls" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $mode := $v.mtls.mode -}}
{{- $exclusions := list -}}
{{- range $key, $entry := ($v.mtls.exclusions | default dict) -}}
  {{- $path := printf "mtls.exclusions.%s" $key -}}
  {{- if eq $.mesh "none" -}}
    {{- fail (printf "posture: %s: exclusions need a mesh to accept plaintext beside mTLS; mesh is none" $path) -}}
  {{- end -}}
  {{- if ne $mode "STRICT" -}}
    {{- fail (printf "posture: %s: exclusions only apply with mtls.mode STRICT; mode is %s (%s)" $path $mode (ternary "every port already accepts plaintext" "the chart isn't managing mTLS" (eq $mode "PERMISSIVE"))) -}}
  {{- end -}}
  {{- $ports := $entry -}}
  {{- $selector := "name" -}}
  {{- if kindIs "map" $entry -}}
    {{- $ports = $entry.ports -}}
    {{- $selector = $entry.selector | default "name" -}}
  {{- end -}}
  {{- $intPorts := list -}}
  {{- range $ports -}}{{- $intPorts = append $intPorts (int .) -}}{{- end -}}
  {{- $name := include "posture.name" (dict "root" $root "rule" $path "fixed" (printf "allow-plaintext-to-%s" $key)) -}}
  {{- $exclusions = append $exclusions (dict
    "key" $key "name" $name "rule" $path
    "labels" (dict (include "posture.selectorLabel" $selector) $key)
    "ports" ($intPorts | uniq)) -}}
{{- end -}}
{{- if ne .mesh "none" -}}
  {{- if ne $mode "inherit" -}}
    {{- $_ := set .fixed "mtlsNamespace" (dict "name" (include "posture.name" (dict "root" $root "rule" "mtls.mode" "fixed" (printf "mtls-%s" (lower $mode)))) "rule" "mtls.mode") -}}
  {{- end -}}
  {{- if eq $mode "PERMISSIVE" -}}
    {{- $_ := set .fixed "plaintextAll" (dict "name" (include "posture.name" (dict "root" $root "rule" "mtls.mode" "fixed" "allow-plaintext-to-all")) "rule" "mtls.mode") -}}
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
{{- $_ := set .out "mtls" (dict "mode" $mode "exclusions" $exclusions) -}}
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
Input: dict "root" "out"; sets out.exceptions (see the model's shape above).
*/}}
{{- define "posture.exceptions" -}}
{{- $v := .root.Values -}}
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
  {{- range $policy, $p := $entry.policies -}}
    {{- $path := printf "exceptions.%s.policies.%s" $workload $policy -}}
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
{{- $_ := set .out "exceptions" (dict "enabled" $enabled "name" "posture-exceptions" "policies" $policies "expired" $expired) -}}
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
