{{- define "baikal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "baikal.fullname" -}}
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

{{- define "baikal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "baikal.labels" -}}
helm.sh/chart: {{ include "baikal.chart" . }}
{{ include "baikal.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "baikal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "baikal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "baikal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "baikal.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "baikal.image" -}}
{{- $tag := .Values.image.tag }}
{{- if not $tag }}
{{- $tag = printf "%s-%s" .Chart.AppVersion .Values.image.variant }}
{{- end }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{- define "baikal.configSecretName" -}}
{{- default (include "baikal.fullname" .) .Values.config.existingSecret }}
{{- end }}

{{- define "baikal.dbSecretName" -}}
{{- default (include "baikal.fullname" .) .Values.database.existingSecret }}
{{- end }}

{{- define "baikal.dbSecretPasswordKey" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecretPasswordKey }}
{{- else }}
{{- print "mysql-password" }}
{{- end }}
{{- end }}

{{/* Baikal expects ":port" appended to the host only when it is not 3306. */}}
{{- define "baikal.mysqlHost" -}}
{{- $host := required "database.host is required when config.manage=true" .Values.database.host }}
{{- $port := int (default 3306 .Values.database.port) }}
{{- if eq $port 3306 }}
{{- $host }}
{{- else }}
{{- printf "%s:%d" $host $port }}
{{- end }}
{{- end }}

{{- define "baikal.adminPasswordHash" -}}
{{- if .Values.config.adminPasswordHash }}
{{- .Values.config.adminPasswordHash }}
{{- else if .Values.config.adminPassword }}
{{- printf "admin:%s:%s" .Values.config.authRealm .Values.config.adminPassword | sha256sum }}
{{- else }}
{{- required "Set config.adminPassword or config.adminPasswordHash when config.manage=true" "" }}
{{- end }}
{{- end }}

{{/* Memoized in .Values so every template in a render gets the same key. */}}
{{- define "baikal.encryptionKey" -}}
{{- if not (hasKey .Values "_encryptionKey") }}
{{- $key := .Values.config.encryptionKey }}
{{- if not $key }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "baikal.fullname" .) }}
{{- if and $existing $existing.data (hasKey $existing.data "encryption-key") }}
{{- $key = index $existing.data "encryption-key" | b64dec }}
{{- else }}
{{- $key = randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- $_ := set .Values "_encryptionKey" $key }}
{{- end }}
{{- .Values._encryptionKey }}
{{- end }}

{{/* mysql_password is left as a placeholder and substituted by the init container,
     so database.existingSecret keeps working. */}}
{{- define "baikal.configFile" -}}
system:
    configured_version: '{{ .Values.config.configuredVersion | default .Chart.AppVersion }}'
    timezone: '{{ .Values.config.timezone }}'
    card_enabled: {{ .Values.config.cardEnabled }}
    cal_enabled: {{ .Values.config.calEnabled }}
    invite_from: '{{ .Values.config.inviteFrom }}'
    dav_auth_type: '{{ .Values.config.authType }}'
    admin_passwordhash: '{{ include "baikal.adminPasswordHash" . }}'
    failed_access_message: '{{ .Values.config.failedAccessMessage }}'
    auth_realm: '{{ .Values.config.authRealm }}'
    base_uri: '{{ .Values.config.baseUri }}'
database:
    backend: '{{ .Values.database.backend }}'
    encryption_key: '{{ include "baikal.encryptionKey" . }}'
    mysql_host: '{{ include "baikal.mysqlHost" . }}'
    mysql_dbname: '{{ .Values.database.name }}'
    mysql_username: '{{ .Values.database.user }}'
    mysql_password: %MYSQL_PASSWORD%
{{- end }}
