{{/*
Expand the name of the chart.
*/}}
{{- define "kcm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kcm.fullname" -}}
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
{{- define "kcm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kcm.labels" -}}
k0rdent.mirantis.com/managed: "true"
helm.sh/chart: {{ include "kcm.chart" . }}
{{ include "kcm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kcm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kcm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Dynamically determine the version based on enterprise.enabled or community.enabled
*/}}
{{- define "kcm.version" -}}
{{- if eq .Values.type "enterprise" -}}
{{- .Values.enterprise.version -}}
{{- else if eq .Values.type "community" -}}
{{- .Values.community.version -}}
{{- end -}}
{{- end }}

{{/*
Dynamically determine the CAPI template based on enterprise.enabled or community.enabled
*/}}
{{- define "kcm.template.capi" -}}
{{- if eq .Values.type "enterprise" -}}
{{- .Values.enterprise.templates.capi -}}
{{- else if eq .Values.type "community" -}}
{{- .Values.community.templates.capi -}}
{{- end -}}
{{- end }}

{{/*
Dynamically determine the KCM template based on enterprise.enabled or community.enabled
*/}}
{{- define "kcm.template.kcm" -}}
{{- if eq .Values.type "enterprise" -}}
{{- .Values.enterprise.templates.kcm -}}
{{- else if eq .Values.type "community" -}}
{{- .Values.community.templates.kcm -}}
{{- end -}}
{{- end }}

{{/*
Dynamically determine the regional template based on enterprise.enabled or community.enabled
*/}}
{{- define "kcm.template.regional" -}}
{{- if eq .Values.type "enterprise" -}}
{{- .Values.enterprise.templates.regional -}}
{{- else if eq .Values.type "community" -}}
{{- .Values.community.templates.regional -}}
{{- end -}}
{{- end }}
