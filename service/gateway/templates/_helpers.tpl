{{/*
Expand the name of the chart.
*/}}
{{- define "gateway.name" -}}
{{- $chartName := "gateway" -}}
{{- if and .Chart .Chart.Name -}}
{{- $chartName = .Chart.Name -}}
{{- end -}}
{{- default $chartName .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "gateway.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $chartName := "gateway" -}}
{{- if and .Chart .Chart.Name -}}
{{- $chartName = .Chart.Name -}}
{{- end -}}
{{- $name := default $chartName .Values.nameOverride }}
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
{{- define "gateway.chart" -}}
{{- if and .Chart .Chart.Name .Chart.Version -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- "gateway-unknown" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "gateway.labels" -}}
k0rdent.mirantis.com/managed: "true"
helm.sh/chart: {{ include "gateway.chart" . }}
{{ include "gateway.selectorLabels" . }}
{{- if and .Chart .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
