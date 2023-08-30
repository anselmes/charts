database_host: {{ tuple "maas_db" "internal" . | include "helm-toolkit.endpoints.hostname_fqdn_endpoint_lookup" }}
database_name: {{ .Values.endpoints.maas_db.auth.user.database }}
database_pass: {{ .Values.endpoints.maas_db.auth.user.password }}
database_user: {{ .Values.endpoints.maas_db.auth.user.username }}

{{- if empty .Values.conf.maas.url.maas_url }}
maas_url: {{ tuple "maas_region" "public" "region_api" . | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" | quote }}
{{- else }}
maas_url: {{ .Values.conf.maas.url.maas_url }}
{{- end }}
