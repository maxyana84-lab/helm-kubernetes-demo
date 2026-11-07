{{/* Chart name, optionally overridden. */}}
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Full release name, limited to 63 chars (DNS label limit). */}}
{{- define "myapp.fullname" -}}
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

{{/* Per-tier resource name: <fullname>-<component>, still <= 63 chars.
     Usage: include "myapp.componentName" (dict "root" . "component" "frontend") */}}
{{- define "myapp.componentName" -}}
{{- $max := int (sub 62 (len .component)) -}}
{{- printf "%s-%s" (include "myapp.fullname" .root | trunc $max | trimSuffix "-") .component -}}
{{- end -}}

{{- define "myapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels (immutable, so keep minimal). */}}
{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Common labels. */}}
{{- define "myapp.labels" -}}
helm.sh/chart: {{ include "myapp.chart" .root }}
{{ include "myapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: myapp
environment: {{ .root.Values.environment }}
{{- end -}}

{{/* Name of the object holding DB credentials (ConfigMap, Secret, SealedSecret or ExternalSecret target). */}}
{{- define "myapp.secretsName" -}}
{{- printf "%s-secrets" (include "myapp.fullname" . | trunc 55 | trimSuffix "-") -}}
{{- end -}}

{{/* envFrom entry for credentials, depends on secrets.mode. */}}
{{- define "myapp.secretsEnvFrom" -}}
{{- if eq .Values.secrets.mode "configmap" }}
- configMapRef:
    name: {{ include "myapp.secretsName" . }}
{{- else }}
- secretRef:
    name: {{ include "myapp.secretsName" . }}
{{- end }}
{{- end -}}

{{/* Name of the ConfigMap with the external DB connection string. */}}
{{- define "myapp.dbConnName" -}}
{{- printf "%s-db-connection" (include "myapp.fullname" . | trunc 49 | trimSuffix "-") -}}
{{- end -}}

{{/* DB host seen by the backend. */}}
{{- define "myapp.dbHost" -}}
{{- if .Values.database.external -}}
{{- required "database.externalHost is required when database.external is true" .Values.database.externalHost -}}
{{- else -}}
{{- include "myapp.componentName" (dict "root" . "component" "database") -}}
{{- end -}}
{{- end -}}
