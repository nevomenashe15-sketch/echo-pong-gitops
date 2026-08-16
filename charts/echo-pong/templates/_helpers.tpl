{{/*
Naming / labelling helpers. Same scheme as the echo-ai-pipeline chart so the
two repositories stay conventionally identical.
*/}}

{{- define "echo-pong.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "echo-pong.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "echo-pong.labels" -}}
app.kubernetes.io/name: {{ include "echo-pong.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: echo-pong
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.environment }}
echo-pong.io/environment: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "echo-pong.selectorLabels" -}}
app.kubernetes.io/name: {{ include "echo-pong.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "echo-pong.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "echo-pong.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference.

Digest wins whenever it is set, which is what every committed environment
values file does: production (and staging, and dev) always deploy an
immutable `repo@sha256:...` reference. The `:tag` branch exists only so a
developer can render/point the chart at a mutable tag locally before a digest
has been produced — it is never used by a real environment overlay.
*/}}
{{- define "echo-pong.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Kubernetes Secret that External Secrets Operator materialises and
that the Deployment mounts. Both sides must agree, so it is derived once here.
*/}}
{{- define "echo-pong.secretName" -}}
{{- default (printf "%s-token" (include "echo-pong.fullname" .)) .Values.externalSecret.targetSecretName -}}
{{- end -}}

{{/*
Absolute file path handed to the app via SECRET_FILE_PATH. Derived from the
mount directory + key so the two can never drift apart.
*/}}
{{- define "echo-pong.secretFilePath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.secret.mountPath) .Values.secret.key -}}
{{- end -}}
