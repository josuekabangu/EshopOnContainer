{{/* Return the full name of the release */}}
{{- define "eshop.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Standard labels */}}
{{- define "eshop.labels" -}}
app.kubernetes.io/name: {{ include "eshop.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "eshop.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "eshop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eshop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
