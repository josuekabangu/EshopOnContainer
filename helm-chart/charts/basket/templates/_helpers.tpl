{{/*
Return the name of the chart
*/}}
{{- define "basket.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Return the full name of the release
*/}}
{{- define "basket.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Return common labels
*/}}
{{- define "basket.labels" -}}
app.kubernetes.io/name: {{ include "basket.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Return selector labels
*/}}
{{- define "basket.selectorLabels" -}}
app.kubernetes.io/name: {{ include "basket.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
