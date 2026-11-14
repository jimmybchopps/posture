{{/*
Istio ambient AuthorizationPolicy helpers. Everything here reads the model (posture.model),
never raw values. Helpers that build data "return" by setting keys on an `out` dict, like
_model.tpl.

ztunnel enforces these at the destination, at L4, after unwrapping HBONE: it sees the original
destination port and the client's mesh identity, which the NetworkPolicies can't (between
meshed pods they only see 15008).
*/}}

{{/*
The most ports one rule's AuthorizationPolicy may list once ranges are expanded.
*/}}
{{- define "posture.istio.maxPorts" -}}1024{{- end -}}

{{/*
A complete security.istio.io/v1 object: an AuthorizationPolicy, or the kind given.
Input: dict "root" $ "name" <name> "rule" <values path> "spec" <dict> ["kind" <kind>]
       ["profile" <name>]
*/}}
{{- define "posture.istio.object" -}}
apiVersion: security.istio.io/v1
kind: {{ .kind | default "AuthorizationPolicy" }}
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "posture.labels" .root | nindent 4 }}
  annotations:
    {{- include "posture.annotations" (dict "rule" .rule "profile" .profile) | nindent 4 }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end -}}

{{/*
AuthorizationPolicy `from` entries for a model peer ("same" is the release namespace):
  serviceAccount, namespace same or X  -> principals: [<trustDomain>/ns/<ns>/sa/<sa>]
  serviceAccount, namespace any        -> principals: [<sa> in any namespace], a suffix match
                                          ("*" then "/sa/<sa>"; not written out here, since
                                          that sequence would end this comment)
  no serviceAccount, namespace any     -> principals: ["*"]  (any mesh identity)
  no serviceAccount, namespace same/X  -> namespaces: [<ns>]
  cidrs                                -> one entry per CIDR: ipBlocks, plus notIpBlocks for
                                          its except list
Labels can't be checked here: without a serviceAccount the NetworkPolicy checks them and this
layer checks the namespace (NOTES.txt warns). One entry per CIDR keeps each except list bound
to its own CIDR (entries are OR'd; fields within one entry are AND'd).
Input: dict "model" <model> "peer" <model peer> "out" <dict>; sets out.from.
*/}}
{{- define "posture.istio.from" -}}
{{- $peer := .peer -}}
{{- $from := list -}}
{{- if $peer.inCluster -}}
  {{- $scope := $peer.namespace.scope -}}
  {{- $ns := ternary .model.namespace $peer.namespace.name (eq $scope "same") -}}
  {{- $source := dict -}}
  {{- if $peer.serviceAccount -}}
    {{- if eq $scope "all" -}}
      {{- $source = dict "principals" (list (printf "*/sa/%s" $peer.serviceAccount)) -}}
    {{- else -}}
      {{- $source = dict "principals" (list (printf "%s/ns/%s/sa/%s" .model.trustDomain $ns $peer.serviceAccount)) -}}
    {{- end -}}
  {{- else if eq $scope "all" -}}
    {{- $source = dict "principals" (list "*") -}}
  {{- else -}}
    {{- $source = dict "namespaces" (list $ns) -}}
  {{- end -}}
  {{- $from = append $from (dict "source" $source) -}}
{{- else -}}
  {{- range $peer.cidrs -}}
    {{- $source := dict "ipBlocks" (list .cidr) -}}
    {{- if .except -}}{{- $_ := set $source "notIpBlocks" .except -}}{{- end -}}
    {{- $from = append $from (dict "source" $source) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "from" $from -}}
{{- end -}}

{{/*
AuthorizationPolicy ports for a model rule, as strings: TCP only (ztunnel carries TCP; UDP and
SCTP are left to the NetworkPolicy, which sees them on their real port), never 15008 (ztunnel
checks the original port, after unwrapping HBONE), ranges expanded (operation.ports has no
range form), duplicates dropped, at most posture.istio.maxPorts.
Empty when the rule has no TCP ports; the caller then renders no policy for it.
Input: dict "rule" <model rule> "out" <dict>; sets out.ports.
*/}}
{{- define "posture.istio.ports" -}}
{{- $rule := .rule -}}
{{- $max := include "posture.istio.maxPorts" . | int -}}
{{- $ports := list -}}
{{- $seen := dict -}}
{{- range $rule.ports -}}
  {{- if eq .protocol "TCP" -}}
    {{- $first := int .port -}}
    {{- $last := ternary (int (get . "endPort")) $first (hasKey . "endPort") -}}
    {{- if gt (add (len $ports) (sub $last $first) 1) $max -}}
      {{- fail (printf "posture: %s: its authorization policy would list more than %d ports (Istio can't match a port range, so ranges are listed port by port); narrow the range or split the rule" $rule.rule $max) -}}
    {{- end -}}
    {{- range $p := untilStep $first (int (add $last 1)) 1 -}}
      {{- $s := toString $p -}}
      {{- if and (ne $p 15008) (not (hasKey $seen $s)) -}}
        {{- $_ := set $seen $s true -}}
        {{- $ports = append $ports $s -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "ports" $ports -}}
{{- end -}}
