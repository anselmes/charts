{{/*
Certificate
*/}}
{{- define "common.certificate.tpl" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ include "common.name" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec: {}
{{- end -}}

{{- define "common.certificate" -}}
{{- include "common.util.merge" (append . "common.certificate.tpl") -}}
{{- end -}}
