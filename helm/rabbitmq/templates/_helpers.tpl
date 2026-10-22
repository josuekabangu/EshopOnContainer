{{- define "rabbitmq.labels" -}}
app: rabbitmq
app.kubernetes.io/name: rabbitmq
app.kubernetes.io/part-of: eshop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
