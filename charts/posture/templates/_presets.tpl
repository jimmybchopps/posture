{{/*
Predefined sources and destinations (CLAUDE.md, "Predefined sources and destinations").

They live here, not in values.yaml, so the chart can tell which fields a user set: a user
entry under `sources` or `destinations` is merged over these field by field (see
posture.resolveDefinitions in _model.tpl).

Each preset is either outside the cluster (cidrs) or inside it (namespace plus workload, or a
raw podSelector). workload: any means every pod in the namespace.

requiresMesh is internal (users can't set it): referencing the entry with any other mesh fails.
*/}}

{{- define "posture.privateRanges" -}}
[10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
{{- end -}}

{{- define "posture.presets.sources" -}}
monitoring:
  namespace: prometheus
  workload: prometheus
  serviceAccount: prometheus
ingress-gateway:
  namespace: gateway
  workload: any
{{- end -}}

{{- define "posture.presets.destinations" -}}
{{- $private := include "posture.privateRanges" . -}}
dns:
  namespace: kube-system
  podSelector: { k8s-app: kube-dns }
  ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
kube-api:
  cidrs: {{ $private }}
  ports: [443, 6443]
postgres:
  cidrs: {{ $private }}
  ports: [5432]
redis:
  cidrs: {{ $private }}
  ports: [6379]
https:
  cidrs: {{ $private }}
  ports: [443]
sso:
  cidrs: {{ $private }}
  ports: [443, 8443]
storage:
  cidrs: {{ $private }}
  ports: [443, 9000]
ldap:
  cidrs: {{ $private }}
  ports: [389, 636]
smtp:
  cidrs: {{ $private }}
  ports: [25, 587]
ntp:
  cidrs: {{ $private }}
  ports: [{ port: 123, protocol: UDP }]
syslog:
  cidrs: {{ $private }}
  ports: [{ port: 514, protocol: UDP }, { port: 514, protocol: TCP }, 6514]
egress-gateway:
  namespace: gateway
  workload: any
  ports: [15008]
  requiresMesh:
    mesh: istio
    reason: >-
      it is the HBONE hop to Istio's egress waypoint; Cilium's egress gateway reroutes at
      the node and Linkerd has none, so no destination is needed there
{{- end -}}
