{{/*
Profiles (CLAUDE.md, "Profiles"): chart-defined layers of values that make a known component's
namespace work out of the box. Effective values are built once, in posture.model, by
posture.values:

  1. posture.defaults: the defaults of the keys a profile may set. They are not in values.yaml,
     because Helm merges values.yaml into .Values before any template runs, and a profile must
     be able to tell a user's explicit value from a default.
  2. each enabled profile, in name order, merged by posture.layerProfiles: two profiles that set
     the same value differently fail, and a profile that sets a forbidden key fails.
  3. the user's values (.Values without profiles), merged by posture.deepMerge: they always win.

Helpers "return" by setting keys on an `out` dict, like _model.tpl.
*/}}

{{/*
The defaults of the keys a profile may set (values.yaml shows them commented).
*/}}
{{- define "posture.defaults" -}}
allowSameNamespace: true
allowDNS: true
meshMember: true
mtls:
  mode: STRICT
{{- end -}}

{{/*
The built-in profiles: their setting defaults and required settings. Each has a
"posture.profile.<name>" define that takes dict "settings" <resolved settings> and returns
ordinary values. values.schema.json lists the same profiles and settings.
*/}}
{{- define "posture.profiles.registry" -}}
istio-system:
  required: [apiServerCidrs]
  defaults: {}
istio-ingress:
  required: []
  defaults:
    ports: [443, 80]
    clientCidrs: {{ include "posture.privateRanges" . }}
istio-egress:
  required: []
  defaults:
    ports: [443, 80]
{{- end -}}

{{/*
Keys a profile may never set: facts about the cluster, troubleshooting switches, a naming
choice, and profiles themselves.
*/}}
{{- define "posture.profiles.forbidden" -}}
[mesh, trustDomain, networkPolicy, authorization, policyExceptions, namePrefix, profiles]
{{- end -}}

{{/*
Deep merge for layered values. Maps merge recursively; lists and scalars from over replace
base, decided by presence, so false, [] and 0 win (Sprig's merge skips "empty" values, so it
can't be used). A nil value in over counts as absent.
Input: dict "base" <dict> "over" <dict> "out" <dict>; sets out.result (a new dict).
*/}}
{{- define "posture.deepMerge" -}}
{{- $result := deepCopy (.base | default dict) -}}
{{- range $key, $value := (.over | default dict) -}}
  {{- if kindIs "invalid" $value -}}
  {{- else if and (kindIs "map" $value) (kindIs "map" (get $result $key)) -}}
    {{- $sub := dict -}}
    {{- $_ := include "posture.deepMerge" (dict "base" (get $result $key) "over" $value "out" $sub) -}}
    {{- $_ := set $result $key $sub.result -}}
  {{- else -}}
    {{- $_ := set $result $key (deepCopy $value) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "result" $result -}}
{{- end -}}

{{/*
Merge one profile's output into the profile layer, failing on a conflict with another profile,
and recording which profile set each path (maps and leaves) in origins.
Input: dict "layer" <dict, modified> "over" <dict> "profile" <name> "origins" <dict, modified>
       "path" <prefix, "" at the top>
*/}}
{{- define "posture.mergeProfile" -}}
{{- $ctx := . -}}
{{- range $key, $value := .over -}}
{{- if not (kindIs "invalid" $value) -}}
  {{- $path := ternary $key (printf "%s.%s" $ctx.path $key) (eq $ctx.path "") -}}
  {{- $has := hasKey $ctx.layer $key -}}
  {{- $existing := get $ctx.layer $key -}}
  {{- if kindIs "map" $value -}}
    {{- if and $has (not (kindIs "map" $existing)) -}}
      {{- fail (printf "posture: profiles.%s and profiles.%s both set %s (%s vs a map)" (get $ctx.origins $path) $ctx.profile $path (toJson $existing)) -}}
    {{- end -}}
    {{- if not $has -}}{{- $_ := set $ctx.layer $key dict -}}{{- end -}}
    {{- if not (hasKey $ctx.origins $path) -}}{{- $_ := set $ctx.origins $path $ctx.profile -}}{{- end -}}
    {{- $_ := include "posture.mergeProfile" (dict "layer" (get $ctx.layer $key) "over" $value "profile" $ctx.profile "origins" $ctx.origins "path" $path) -}}
  {{- else if $has -}}
    {{- if kindIs "map" $existing -}}
      {{- fail (printf "posture: profiles.%s and profiles.%s both set %s (a map vs %s)" (get $ctx.origins $path) $ctx.profile $path (toJson $value)) -}}
    {{- end -}}
    {{- if ne (toJson $existing) (toJson $value) -}}
      {{- fail (printf "posture: profiles.%s and profiles.%s both set %s (%s vs %s)" (get $ctx.origins $path) $ctx.profile $path (toJson $existing) (toJson $value)) -}}
    {{- end -}}
  {{- else -}}
    {{- $_ := set $ctx.layer $key (deepCopy $value) -}}
    {{- $_ := set $ctx.origins $path $ctx.profile -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Layer profile outputs: the forbidden-key check, then posture.mergeProfile for each, in the
order given.
Input: dict "outputs" (list (dict "name" <profile> "values" <dict>)) "out" <dict>; sets
out.layer and out.origins.
*/}}
{{- define "posture.layerProfiles" -}}
{{- $forbidden := include "posture.profiles.forbidden" . | fromYamlArray -}}
{{- $layer := dict -}}
{{- $origins := dict -}}
{{- range .outputs -}}
  {{- $name := .name -}}
  {{- range $key := keys .values | sortAlpha -}}
    {{- if has $key $forbidden -}}
      {{- fail (printf "posture: internal: profile %s sets %s, which profiles may not set" $name $key) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := include "posture.mergeProfile" (dict "layer" $layer "over" .values "profile" $name "origins" $origins "path" "") -}}
{{- end -}}
{{- $_ := set .out "layer" $layer -}}
{{- $_ := set .out "origins" $origins -}}
{{- end -}}

{{/*
The effective values: defaults, then enabled profiles, then the user's values.
Input: dict "root" $ "out" <dict>; sets out.values, out.origins (path -> profile, for paths a
profile set), and out.profiles ([{ name, enabled, settings }], every profile the user listed,
in name order; settings are resolved for enabled ones).
*/}}
{{- define "posture.values" -}}
{{- $user := .root.Values -}}
{{- $registry := include "posture.profiles.registry" . | fromYaml -}}
{{- $outputs := list -}}
{{- $profiles := list -}}
{{- $listed := $user.profiles | default dict -}}
{{- range $name := keys $listed | sortAlpha -}}
  {{- $entry := get $listed $name | default dict -}}
  {{- $known := get $registry $name -}}
  {{- if not $known -}}
    {{- fail (printf "posture: profiles.%s: unknown profile; known: %s" $name (keys $registry | sortAlpha | join ", ")) -}}
  {{- end -}}
  {{- if eq (include "posture.enabled" $entry) "true" -}}
    {{- $settingsOut := dict -}}
    {{- $_ := include "posture.deepMerge" (dict "base" $known.defaults "over" ($entry.settings | default dict) "out" $settingsOut) -}}
    {{- $settings := $settingsOut.result -}}
    {{- range $known.required -}}
      {{- if not (get $settings .) -}}
        {{- fail (printf "posture: profiles.%s.settings.%s: required" $name .) -}}
      {{- end -}}
    {{- end -}}
    {{- $values := include (printf "posture.profile.%s" $name) (dict "settings" $settings) | fromYaml -}}
    {{- $outputs = append $outputs (dict "name" $name "values" $values) -}}
    {{- $profiles = append $profiles (dict "name" $name "enabled" true "settings" $settings) -}}
  {{- else -}}
    {{- $profiles = append $profiles (dict "name" $name "enabled" false) -}}
  {{- end -}}
{{- end -}}
{{- $layered := dict -}}
{{- $_ := include "posture.layerProfiles" (dict "outputs" $outputs "out" $layered) -}}
{{- $base := dict -}}
{{- $_ := include "posture.deepMerge" (dict "base" (include "posture.defaults" . | fromYaml) "over" $layered.layer "out" $base) -}}
{{- $effective := dict -}}
{{- $_ := include "posture.deepMerge" (dict "base" $base.result "over" (omit $user "profiles") "out" $effective) -}}
{{- $_ := set .out "values" $effective.result -}}
{{- $_ := set .out "origins" $layered.origins -}}
{{- $_ := set .out "profiles" $profiles -}}
{{- end -}}

{{/*
istio-system: Istio's control plane (istiod, ztunnel). Not in the mesh data plane, and Istio's
root namespace, where namespace-wide authorization and mTLS objects would apply mesh-wide: so
meshMember is false. istio-cni belongs in kube-system, which admission policies never
evaluate. ztunnel reaches istiod within the namespace (allowSameNamespace); its HBONE runs
inside the application pods' network namespaces, so it needs no rule here.
Exceptions: every policy the policy chart turns on by default (audit-default ones included, so a
site enforcing all of them isn't bitten) that istiod or ztunnel fail and Istio's charts have no
setting to meet. What a site can set at install (images pinned by digest, a memory limit) isn't
excepted: require-image-digest and require-resource-limits are the site's to meet.
Settings: apiServerCidrs (required), where the API server calls istiod's webhooks from.
*/}}
{{- define "posture.profile.istio-system" -}}
meshMember: false
exceptions:
  istiod:
    policies:
      disallow-automount-service-account-token:
        kind: ValidatingAdmissionPolicy
        reason: "istiod watches the Kubernetes API with its service account token, and the istiod chart has no setting for automountServiceAccountToken"
      disallow-mesh-opt-out:
        kind: ValidatingAdmissionPolicy
        reason: "Istio labels and annotates istiod to keep it out of the data plane: it's the mesh's control plane"
      restrict-seccomp:
        kind: ValidatingAdmissionPolicy
        reason: "the istiod chart sets no seccompProfile"
      require-probes:
        kind: ValidatingAdmissionPolicy
        reason: "the istiod chart sets a readiness probe only, with no setting for a liveness probe"
  ztunnel:
    policies:
      disallow-automount-service-account-token:
        kind: ValidatingAdmissionPolicy
        reason: "the ztunnel chart has no setting for automountServiceAccountToken"
      disallow-mesh-opt-out:
        kind: ValidatingAdmissionPolicy
        reason: "Istio labels and annotates ztunnel to keep it out of the data plane: it is the data plane"
      disallow-privilege-escalation:
        kind: ValidatingAdmissionPolicy
        reason: "ztunnel needs allowPrivilegeEscalation for its added capabilities"
      require-drop-all-capabilities:
        kind: ValidatingAdmissionPolicy
        reason: "ztunnel adds NET_ADMIN, SYS_ADMIN, and NET_RAW to redirect pod traffic"
      require-run-as-non-root:
        kind: ValidatingAdmissionPolicy
        reason: "ztunnel runs as root to enter pod network namespaces"
      disallow-host-path:
        kind: ValidatingAdmissionPolicy
        reason: "ztunnel shares the /var/run/ztunnel socket with istio-cni"
      restrict-volume-types:
        kind: ValidatingAdmissionPolicy
        reason: "ztunnel shares the /var/run/ztunnel socket with istio-cni"
      restrict-seccomp:
        kind: ValidatingAdmissionPolicy
        reason: "the ztunnel chart sets no seccompProfile"
      require-probes:
        kind: ValidatingAdmissionPolicy
        reason: "the ztunnel chart sets a readiness probe only, with no setting for a liveness probe"
ingress:
  istiod:
    from:
      any:                      # xDS and the CA: ztunnel, gateways, and waypoints anywhere
        namespace: any
        ports: [15012]
      apiserver:                # the API server calling istiod's webhooks
        cidrs: {{ toJson .settings.apiServerCidrs }}
        ports: [15017]
    sources:
      monitoring: [15014]
  ztunnel:
    sources:
      monitoring: [15020]
egress:
  istiod:
    destinations:
      kube-api: {}
{{- end -}}

{{/*
istio-ingress: the ingress gateway's namespace (ingress-gateway). Clients connect on the
listener ports from clientCidrs; the gateway reaches meshed backends as HBONE on 15008, so it
never needs each application's ports (a backend outside the mesh needs its own egress rule),
and istiod on 15012 for xDS. The gateway is Istio's own proxy, not in the mesh data plane:
meshMember is false. Two exceptions for the pods the boundary chart labels
app.kubernetes.io/component: ingress-gateway: disallow-mesh-opt-out (Istio labels its gateway
pods sidecar.istio.io/inject=false, which is what makes the gateway the mesh's own proxy) and
require-probes (audit by default; Istio sets no liveness probe and has no setting for one).
Everything else boundary makes compliant through the Gateway's infrastructure parameters.
Settings: ports (default 443, 80), clientCidrs (default the private ranges).
*/}}
{{- define "posture.profile.istio-ingress" -}}
meshMember: false
exceptions:
  ingress-gateway:              # the convention shared with boundary
    selector: component
    policies:
      disallow-mesh-opt-out:
        kind: ValidatingAdmissionPolicy
        reason: "Istio labels its gateway pods sidecar.istio.io/inject=false: the gateway is the mesh's own proxy, not a workload in it"
      require-probes:
        kind: ValidatingAdmissionPolicy
        reason: "Istio's gateway pods have startup and readiness probes only, with no setting for a liveness probe"
ingress:
  any:
    from:
      clients:
        cidrs: {{ toJson .settings.clientCidrs }}
        ports: {{ toJson .settings.ports }}
egress:
  any:
    to:
      any:                      # HBONE to meshed backends in every namespace
        namespace: any
        ports: [15008]
      istiod:                   # xDS
        namespace: istio-system
        ports: [15012]
{{- end -}}

{{/*
istio-egress: the egress waypoint's namespace (egress-gateway). Every namespace reaches it as
HBONE on 15008; it forwards outside the cluster on the listed ports, to any address: the
boundary chart's host list at the waypoint is the limit on where it goes. istiod on 15012 for
xDS. meshMember is false (Istio's own proxy). Two exceptions for the pods the boundary chart
labels app.kubernetes.io/component: egress-waypoint: disallow-mesh-opt-out (Istio labels its
waypoint pods sidecar.istio.io/inject=false and istio.io/dataplane-mode=none, which is what
makes the waypoint the mesh's own proxy) and require-probes (audit by default; Istio sets no
liveness probe and has no setting for one). Everything else boundary makes compliant through
the Gateway's infrastructure parameters.
Settings: ports (default 443, 80).
*/}}
{{- define "posture.profile.istio-egress" -}}
meshMember: false
exceptions:
  egress-waypoint:              # the convention shared with boundary
    selector: component
    policies:
      disallow-mesh-opt-out:
        kind: ValidatingAdmissionPolicy
        reason: "Istio labels its waypoint pods sidecar.istio.io/inject=false and istio.io/dataplane-mode=none: the waypoint is the mesh's own proxy, not a workload in it"
      require-probes:
        kind: ValidatingAdmissionPolicy
        reason: "Istio's waypoint pods have startup and readiness probes only, with no setting for a liveness probe"
ingress:
  any:
    from:
      any:                      # HBONE from every namespace
        namespace: any
        ports: [15008]
egress:
  any:
    to:
      istiod:                   # xDS
        namespace: istio-system
        ports: [15012]
      external:                 # the hosts boundary approves, wherever they are
        cidrs: [0.0.0.0/0]
        ports: {{ toJson .settings.ports }}
{{- end -}}
