{{- /*
Helper templates for the redis chart
*/ -}}

{{- define "eshop.redis.name" -}}
redis
{{- end }}

{{- define "eshop.redis.fullname" -}}
{{ include "eshop.redis.name" . }}-{{ .Release.Name }}
{{- end }}

{{- define "eshop.redis.labels" -}}
app.kubernetes.io/name: {{ include "eshop.redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
