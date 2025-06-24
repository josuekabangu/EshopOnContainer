{{/*
Expand the name of the chart.
*/}}
{{- define "eshop.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "eshop.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "eshop.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "eshop.labels" -}}
helm.sh/chart: {{ include "eshop.chart" . }}
{{ include "eshop.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "eshop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eshop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "eshop.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "eshop.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Define sub-chart fullnames
*/}}
{{- define "eshop.basket.fullname" -}}
{{- printf "%s-basket" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.catalog.fullname" -}}
{{- printf "%s-catalog" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.catalogdb.fullname" -}}
{{- printf "%s-catalogdb" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.identity.fullname" -}}
{{- printf "%s-identity" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.mobilebff.fullname" -}}
{{- printf "%s-mobilebff" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.ordering.fullname" -}}
{{- printf "%s-ordering" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.orderprocessor.fullname" -}}
{{- printf "%s-orderprocessor" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.paymentprocessor.fullname" -}}
{{- printf "%s-paymentprocessor" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.rabbitmq.fullname" -}}
{{- printf "%s-rabbitmq" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.redis.fullname" -}}
{{- printf "%s-redis" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.webapp.fullname" -}}
{{- printf "%s-webapp" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "eshop.webhooks.fullname" -}}
{{- printf "%s-webhooks" (include "eshop.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
