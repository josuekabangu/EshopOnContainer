{{- define "eshop-platform.labels" -}}
app.kubernetes.io/name: eshop-platform
app.kubernetes.io/part-of: eshop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
