{{- /*
Expand the name of the chart.
*/ -}}
{{- define "eshop.catalogdb.name" -}}
catalogdb
{{- end }}

{{- /*
Create a default fully qualified app name.
*/ -}}
{{- define "eshop.catalogdb.fullname" -}}
{{ printf "%s-%s" .Release.Name (include "eshop.catalogdb.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
Common labels
*/ -}}
{{- define "eshop.catalogdb.labels" -}}
app.kubernetes.io/name: {{ include "eshop.catalogdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /*
Selector labels for catalogdb
*/ -}}
{{- define "eshop.catalogdb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eshop.catalogdb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
