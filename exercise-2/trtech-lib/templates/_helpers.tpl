{{/*
trtech-lib: library chart. It renders nothing on its own, it only provides named templates.
Every template expects the FULL root context of the calling chart: {{ include "trtech-lib.xxx" . }}
Inside these templates `.Chart` and `.Values` therefore belong to the calling service.

Expected values of a service:
  image.repository, image.tag, replicaCount, containerPort, service.port,
  env (map), probes.liveness/readiness (path, initialDelaySeconds, periodSeconds),
  resources, team, costCenter (or global.team / global.costCenter), pdb.minAvailable
*/}}

{{/* Release-qualified name, max 63 chars. */}}
{{- define "trtech-lib.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Labels used in selectors (immutable, keep minimal). */}}
{{- define "trtech-lib.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Standard company labels: app, version, team, cost-center + app.kubernetes.io/*. */}}
{{- define "trtech-lib.labels" -}}
{{- $g := .Values.global | default dict -}}
{{- $version := .Values.image.tag | default .Chart.AppVersion -}}
{{ include "trtech-lib.selectorLabels" . }}
app: {{ .Chart.Name }}
version: {{ $version | quote }}
team: {{ required (printf "%s: set .Values.team or global.team" .Chart.Name) (.Values.team | default $g.team) | quote }}
cost-center: {{ required (printf "%s: set .Values.costCenter or global.costCenter" .Chart.Name) (.Values.costCenter | default $g.costCenter) | quote }}
app.kubernetes.io/version: {{ $version | quote }}
app.kubernetes.io/part-of: {{ $g.partOf | default "platform" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Preferred anti-affinity: spread the pods of one service across nodes. */}}
{{- define "trtech-lib.podantiaffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "trtech-lib.selectorLabels" . | nindent 12 }}
{{- end -}}

{{/* Full Deployment with probes, resources, anti-affinity and topologySpreadConstraints. */}}
{{- define "trtech-lib.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "trtech-lib.fullname" . }}
  labels:
    {{- include "trtech-lib.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "trtech-lib.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "trtech-lib.labels" . | nindent 8 }}
    spec:
      affinity:
        {{- include "trtech-lib.podantiaffinity" . | nindent 8 }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "trtech-lib.selectorLabels" . | nindent 14 }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
          {{- with .Values.env }}
          env:
            {{- range $k, $v := . }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
          {{- end }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds | default 10 }}
            periodSeconds: {{ .Values.probes.liveness.periodSeconds | default 10 }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds | default 5 }}
            periodSeconds: {{ .Values.probes.readiness.periodSeconds | default 5 }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
{{- end -}}

{{- define "trtech-lib.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "trtech-lib.fullname" . }}
  labels:
    {{- include "trtech-lib.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  selector:
    {{- include "trtech-lib.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
{{- end -}}

{{/* Ingress only from namespaces labelled role=frontend. */}}
{{- define "trtech-lib.networkpolicy" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "trtech-lib.fullname" . }}
  labels:
    {{- include "trtech-lib.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "trtech-lib.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              role: frontend
      ports:
        - protocol: TCP
          port: {{ .Values.containerPort }}
{{- end -}}

{{- define "trtech-lib.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "trtech-lib.fullname" . }}
  labels:
    {{- include "trtech-lib.labels" . | nindent 4 }}
spec:
  minAvailable: {{ required "pdb.minAvailable is required" .Values.pdb.minAvailable }}
  selector:
    matchLabels:
      {{- include "trtech-lib.selectorLabels" . | nindent 6 }}
{{- end -}}
