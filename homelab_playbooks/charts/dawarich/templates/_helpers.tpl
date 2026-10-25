{{/*
Expand the name of the chart.
*/}}
{{- define "dawarich.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dawarich.fullname" -}}
{{- printf "%s" (include "dawarich.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dawarich.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "dawarich.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "dawarich.secretName" -}}
{{- if .Values.existingSecret -}}
{{ .Values.existingSecret }}
{{- else -}}
{{ include "dawarich.fullname" . }}-secret
{{- end }}
{{- end }}

{{- define "dawarich.redisUrl" -}}
redis://{{ include "dawarich.fullname" . }}-redis:6379
{{- end }}

{{- define "dawarich.dbHost" -}}
{{ .Values.externalDatabase.host }}
{{- end }}

{{/*
Common environment block shared by app and sidekiq containers.
*/}}
{{- define "dawarich.commonEnv" -}}
- name: RAILS_ENV
  value: {{ .Values.app.railsEnv | quote }}
- name: APPLICATION_HOSTS
  value: {{ .Values.app.applicationHosts | quote }}
- name: APPLICATION_PROTOCOL
  value: {{ .Values.app.applicationProtocol | quote }}
- name: TIME_ZONE
  value: {{ .Values.app.timeZone | quote }}
- name: SELF_HOSTED
  value: {{ .Values.app.selfHosted | quote }}
- name: STORE_GEODATA
  value: {{ .Values.app.storeGeodata | quote }}
- name: PHOTON_API_HOST
  value: {{ .Values.app.photonApiHost | quote }}
- name: BACKGROUND_PROCESSING_CONCURRENCY
  value: {{ .Values.app.backgroundProcessingConcurrency | quote }}
- name: RAILS_LOG_TO_STDOUT
  value: {{ .Values.app.railsLogToStdout | quote }}
- name: REDIS_URL
  value: {{ include "dawarich.redisUrl" . | quote }}
- name: DATABASE_HOST
  value: {{ include "dawarich.dbHost" . | quote }}
- name: DATABASE_PORT
  value: "5432"
- name: DATABASE_USERNAME
  value: {{ .Values.postgresql.username | quote }}
- name: DATABASE_NAME
  value: {{ .Values.postgresql.database | quote }}
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "dawarich.secretName" . }}
      key: DATABASE_PASSWORD
## Run as non-root via PUID/PGID (dawarich native support)
- name: PUID
  value: "1000"
- name: PGID
  value: "1000"
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "dawarich.secretName" . }}
      key: DATABASE_URL
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "dawarich.secretName" . }}
      key: SECRET_KEY_BASE
{{- end }}

{{/*
Common volume mounts for app and sidekiq.
*/}}
{{- define "dawarich.volumeMounts" -}}
- name: public
  mountPath: /var/app/public
- name: storage
  mountPath: /var/app/storage
- name: watched
  mountPath: /var/app/tmp/imports/watched
{{- end }}

{{/*
Common volumes.
*/}}
{{- define "dawarich.volumes" -}}
- name: public
  persistentVolumeClaim:
    claimName: {{ include "dawarich.fullname" . }}-public
- name: storage
  persistentVolumeClaim:
    claimName: {{ include "dawarich.fullname" . }}-storage
- name: watched
  persistentVolumeClaim:
    claimName: {{ include "dawarich.fullname" . }}-watched
{{- end }}
