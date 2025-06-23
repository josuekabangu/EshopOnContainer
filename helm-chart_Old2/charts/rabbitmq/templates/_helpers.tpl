{{- /*
Expand the name of the chart.
*/ -}}
{{- define "eshop.rabbitmq.name" -}}
rabbitmq
{{- end }}

{{- /*
Create a default fully qualified app name.
*/ -}}
{{- define "eshop.rabbitmq.fullname" -}}
{{ printf "%s-%s" .Release.Name (include "eshop.rabbitmq.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
Common labels
*/ -}}
{{- define "eshop.rabbitmq.labels" -}}
app.kubernetes.io/name: {{ include "eshop.rabbitmq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /*
Selector labels
*/ -}}
{{- define "eshop.rabbitmq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eshop.rabbitmq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
