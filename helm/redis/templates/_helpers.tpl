{{- define "redis.labels" -}}
app: redis
app.kubernetes.io/name: redis
app.kubernetes.io/part-of: eshop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
