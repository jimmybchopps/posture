{{/*
The model: values normalized once into rules that every renderer reads (CLAUDE.md, "One
model, many renderers"). Renderers call:

  {{- $model := include "posture.model" . | fromJson -}}

Shape:

  mesh, namespace, trustDomain, allowSameNamespace
  networkPolicy: { ingress, egress }      # which directions get NetworkPolicies
  authorization: { enabled }              # whether the mesh's authorization policies render
  fixed:                                  # fixed objects; a key is absent when not wanted
    denyIngress:   { name, rule }         # deny-all-ingress
    denyEgress:    { name, rule }         # deny-all-egress
    sameNamespace: { name, rule }         # allow-same-namespace (allowSameNamespace)
    ambientProbes: { name, rule }         # allow-ingress-from-ambient-probes-to-all (istio)
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

{{- $_ := include "posture.checkCollisions" (dict "fixed" $fixed "rules" $acc.rules) -}}

{{- toJson (dict
  "mesh" $mesh
  "namespace" .Release.Namespace
  "trustDomain" $v.trustDomain
  "networkPolicy" (dict "ingress" $v.networkPolicy.ingress "egress" $v.networkPolicy.egress)
  "authorization" (dict "enabled" $v.authorization.enabled)
  "allowSameNamespace" $v.allowSameNamespace
  "fixed" $fixed
  "rules" $acc.rules) -}}
{{- end -}}

{{/*
Fail if two objects would get the same name, naming both values paths.
Fixed objects are checked first, so a rule that collides with one is reported against it.
Input: dict "fixed" <dict of {name, rule}> "rules" <list>
*/}}
{{- define "posture.checkCollisions" -}}
{{- $seen := dict -}}
{{- $all := list -}}
{{- range $key := list "denyIngress" "denyEgress" "sameNamespace" "ambientProbes" -}}
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
