{{- define "bg.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Release name, max 63 chars. */}}
{{- define "bg.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "bg.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "bg.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* <fullname>-<suffix> within 63 chars. Usage: include "bg.suffixed" (dict "root" . "suffix" "blue") */}}
{{- define "bg.suffixed" -}}
{{- $max := int (sub 62 (len .suffix)) -}}
{{- printf "%s-%s" (include "bg.fullname" .root | trunc $max | trimSuffix "-") .suffix -}}
{{- end -}}

{{- define "bg.slotName" -}}
{{- include "bg.suffixed" (dict "root" .root "suffix" .slot) -}}
{{- end -}}
{{- define "bg.greenServiceName" -}}{{- include "bg.suffixed" (dict "root" . "suffix" "green") -}}{{- end -}}
{{- define "bg.hooksServiceAccount" -}}{{- include "bg.suffixed" (dict "root" . "suffix" "hooks") -}}{{- end -}}

{{- define "bg.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bg.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- define "bg.labels" -}}
{{ include "bg.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Environment shared by all hook containers. */}}
{{- define "bg.hookEnv" -}}
- {name: BLUE, value: {{ include "bg.slotName" (dict "root" . "slot" "blue") | quote }}}
- {name: GREEN, value: {{ include "bg.slotName" (dict "root" . "slot" "green") | quote }}}
- {name: PRIMARY_SVC, value: {{ include "bg.fullname" . | quote }}}
- {name: BLUE_DEFAULT_REPLICAS, value: {{ .Values.blue.replicas | quote }}}
- {name: TIMEOUT, value: {{ .Values.hooks.timeoutSeconds | quote }}}
{{- end -}}

{{/* Shell helpers: wait for a Deployment to finish rolling out (kubectl get only) and scale it (kubectl patch only). */}}
{{- define "bg.shellLib" -}}
set -eu
MAX=$((TIMEOUT / 5))
wait_rollout() {
  name="$1"; i=0
  while [ "$i" -lt "$MAX" ]; do
    want=$(kubectl get deployment "$name" -o jsonpath='{.spec.replicas}')
    gen=$(kubectl get deployment "$name" -o jsonpath='{.metadata.generation}')
    obs=$(kubectl get deployment "$name" -o jsonpath='{.status.observedGeneration}')
    total=$(kubectl get deployment "$name" -o jsonpath='{.status.replicas}')
    upd=$(kubectl get deployment "$name" -o jsonpath='{.status.updatedReplicas}')
    rdy=$(kubectl get deployment "$name" -o jsonpath='{.status.readyReplicas}')
    if [ "${obs:-0}" -ge "${gen:-0}" ] && [ "${total:-0}" = "${want:-0}" ] && [ "${upd:-0}" = "${want:-0}" ] && [ "${rdy:-0}" = "${want:-0}" ]; then
      echo "$name is ready (${want:-0} replicas)"; return 0
    fi
    i=$((i + 1)); sleep 5
  done
  echo "timed out waiting for $name" >&2; return 1
}
scale() { kubectl patch deployment "$1" --type merge -p "{\"spec\":{\"replicas\":$2}}"; }
{{- end -}}

{{- define "bg.validate" -}}
{{- if not (has .Values.activeSlot (list "blue" "green")) -}}
{{- fail (printf "activeSlot must be blue or green (got %q)" (toString .Values.activeSlot)) -}}
{{- end -}}
{{- if not (has (int .Values.canary.weight) (list 0 10 50 100)) -}}
{{- fail (printf "canary.weight must be one of 0, 10, 50, 100 (got %v)" .Values.canary.weight) -}}
{{- end -}}
{{- end -}}
