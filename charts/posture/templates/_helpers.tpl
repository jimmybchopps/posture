{{/*
Common labels for every object this chart renders.
*/}}
{{- define "posture.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
The annotation saying why an object exists: the values key path it came from.
Usage: include "posture.annotations" "ingress.grafana"
*/}}
{{- define "posture.annotations" -}}
posture.dev/rule: {{ . | quote }}
{{- end -}}

{{/*
Name token for a rule's own workload (the target of an ingress rule, the source of an egress
rule): the map key as is, or "all" for "any".
Usage: include "posture.targetToken" "grafana"
*/}}
{{- define "posture.targetToken" -}}
{{- if eq . "any" -}}all{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/*
Name token for a peer (a from/to entry): the map key as is, or for "any":
"all-in-<namespace>", "all-namespaces" (namespace: any), or "all" (namespace omitted).
Usage: include "posture.peerToken" (dict "key" "any" "namespace" "tooling")
*/}}
{{- define "posture.peerToken" -}}
{{- $ns := .namespace | default "" -}}
{{- if ne .key "any" -}}
{{- .key -}}
{{- else if eq $ns "" -}}
all
{{- else if eq $ns "any" -}}
all-namespaces
{{- else -}}
{{- printf "all-in-%s" $ns -}}
{{- end -}}
{{- end -}}

{{/*
The name of a generated object, with namePrefix applied and the length limit enforced.

Either a fixed name:
  include "posture.name" (dict "root" $ "rule" "networkPolicy.ingress" "fixed" "deny-all-ingress")
or the allow convention, allow-<direction>-from-<source>-to-<destination>, with tokens from
posture.targetToken and posture.peerToken:
  include "posture.name" (dict "root" $ "rule" "ingress.grafana.from.keycloak"
    "direction" "ingress" "source" "keycloak" "destination" "grafana")

"rule" is the values key path, used in the error message.
*/}}
{{- define "posture.name" -}}
{{- $base := "" -}}
{{- if .fixed -}}
{{- $base = .fixed -}}
{{- else -}}
{{- if not (and .direction .source .destination) -}}
{{- fail (printf "posture: %s: posture.name needs either fixed, or direction, source, and destination" .rule) -}}
{{- end -}}
{{- $base = printf "allow-%s-from-%s-to-%s" .direction .source .destination -}}
{{- end -}}
{{- $prefix := .root.Values.namePrefix | default "" -}}
{{- $name := ternary (printf "%s-%s" $prefix $base) $base (ne $prefix "") -}}
{{- if gt (len $name) 253 -}}
{{- fail (printf "posture: %s: object name %q is %d characters; the limit is 253" .rule $name (len $name)) -}}
{{- end -}}
{{- $name -}}
{{- end -}}
