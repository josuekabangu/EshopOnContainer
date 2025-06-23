{{- define "basket.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "basket.labels" -}}
app.kubernetes.io/name: basket-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "basket.selectorLabels" -}}
app: basket-api
{{- end }}
