{{- define "vanity.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "vanity.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "vanity.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}