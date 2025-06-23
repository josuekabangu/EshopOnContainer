{{- /*
Expand the name of the chart.
*/ -}}
{{- define "webhooks.name" -}}
webhooks
{{- end }}

{{- /*
Create a default fully qualified app name.
*/ -}}
{{- define "webhooks.fullname" -}}
{{ printf "%s-%s" .Release.Name (include "webhooks.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
Common labels
*/ -}}
{{- define "webhooks.labels" -}}
app.kubernetes.io/name: {{ include "webhooks.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /*
Selector labels
*/ -}}
{{- define "webhooks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webhooks.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
