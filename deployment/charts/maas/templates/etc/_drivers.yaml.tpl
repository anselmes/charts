{{- if .Values.conf.drivers }}
drivers:
{{- range .Values.conf.drivers }}
- comment: {{ .comment }}
{{- if .key_binary }}
  key_binary: !!binary |
{{ .key_binary | indent 4 }}
{{- end }}
{{- if .repository }}
  repository: {{ .repository }}
{{- end }}
  modaliases:
{{ .modaliases | toYaml | indent 4 }}
  module: {{ .module }}
  package: {{ .package }}
{{- if .blacklist }}
  blacklist: {{ .blacklist }}
{{- end }}
{{ end }}
{{- end }}
