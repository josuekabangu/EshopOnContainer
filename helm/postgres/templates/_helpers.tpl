{{- define "postgres.labels" -}}
app: postgres
app.kubernetes.io/name: postgres
app.kubernetes.io/part-of: eshop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
