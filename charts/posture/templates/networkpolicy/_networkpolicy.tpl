{{/*
NetworkPolicy renderer helpers. Everything here reads the model (posture.model), never raw
values. Helpers that build data "return" by setting keys on an `out` dict, like _model.tpl.
*/}}

{{/*
A complete NetworkPolicy.
Input: dict "root" $ "name" <name> "rule" <values path> "spec" <dict>
*/}}
{{- define "posture.np.object" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "posture.labels" .root | nindent 4 }}
  annotations:
    {{- include "posture.annotations" .rule | nindent 4 }}
spec:
  {{- toYaml .spec | nindent 2 }}
{{- end -}}

{{/*
NetworkPolicy peers for a model peer (CLAUDE.md, "Peer translation"):
  labels, namespace omitted   -> podSelector
  labels, namespace X         -> podSelector + namespaceSelector on kubernetes.io/metadata.name
  labels, namespace any       -> podSelector + namespaceSelector: {}
  every pod, namespace omitted -> podSelector: {}
  every pod, namespace X      -> namespaceSelector only
  every pod, namespace any    -> namespaceSelector: {}
  cidrs                       -> one ipBlock per CIDR
Input: dict "peer" <model peer> "out" <dict>; sets out.peers.
*/}}
{{- define "posture.np.peers" -}}
{{- $peer := .peer -}}
{{- $peers := list -}}
{{- if $peer.inCluster -}}
  {{- $entry := dict -}}
  {{- $scope := $peer.namespace.scope -}}
  {{- if $peer.labels -}}
    {{- $_ := set $entry "podSelector" (dict "matchLabels" $peer.labels) -}}
  {{- else if eq $scope "same" -}}
    {{- $_ := set $entry "podSelector" (dict) -}}
  {{- end -}}
  {{- if eq $scope "named" -}}
    {{- $_ := set $entry "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" $peer.namespace.name)) -}}
  {{- else if eq $scope "all" -}}
    {{- $_ := set $entry "namespaceSelector" (dict) -}}
  {{- end -}}
  {{- $peers = append $peers $entry -}}
{{- else -}}
  {{- range $peer.cidrs -}}
    {{- $block := dict "cidr" .cidr -}}
    {{- if .except -}}{{- $_ := set $block "except" .except -}}{{- end -}}
    {{- $peers = append $peers (dict "ipBlock" $block) -}}
  {{- end -}}
{{- end -}}
{{- $_ := set .out "peers" $peers -}}
{{- end -}}

{{/*
NetworkPolicy ports for a model rule. Port numbers become integers again (fromJson makes them
floats). Under mesh: istio, TCP 15008 (HBONE) is added for in-cluster peers, unless exactly
that port is already listed: meshed traffic travels between pods on 15008, so without it the
listed ports would never match. Outside-cluster (cidrs) peers aren't meshed and don't get it.
Input: dict "mesh" <mesh> "rule" <model rule> "out" <dict>; sets out.ports.
*/}}
{{- define "posture.np.ports" -}}
{{- $ports := list -}}
{{- $hasHBONE := false -}}
{{- range .rule.ports -}}
  {{- $p := dict "port" (int .port) "protocol" .protocol -}}
  {{- if hasKey . "endPort" -}}
    {{- $_ := set $p "endPort" (int .endPort) -}}
  {{- else if and (eq (int .port) 15008) (eq .protocol "TCP") -}}
    {{- $hasHBONE = true -}}
  {{- end -}}
  {{- $ports = append $ports $p -}}
{{- end -}}
{{- if and (eq .mesh "istio") .rule.peer.inCluster (not $hasHBONE) -}}
  {{- $ports = append $ports (dict "port" 15008 "protocol" "TCP") -}}
{{- end -}}
{{- $_ := set .out "ports" $ports -}}
{{- end -}}
