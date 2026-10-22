{{/* Étiquettes des objets. Le sélecteur, lui, n'utilise que app : il ne peut plus changer. */}}
{{- define "eshop-service.labels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: eshop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
