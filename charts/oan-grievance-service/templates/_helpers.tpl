{{/*
Full name the upstream chart gives its resources (its "erpnext.fullname", evaluated
with the alias `frappe` as chart name). The sites PVC and the gunicorn and socketio
Services carry this name.
*/}}
{{- define "grievance.frappeFullname" -}}
{{- if .Values.frappe.fullnameOverride -}}
{{- .Values.frappe.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "frappe" .Values.frappe.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "grievance.sitesClaim" -}}
{{- default (include "grievance.frappeFullname" .) .Values.frappe.persistence.worker.existingClaim -}}
{{- end -}}

{{- define "grievance.image" -}}
{{- printf "%s:%s" (required "frappe.image.repository is required" .Values.frappe.image.repository) (required "frappe.image.tag is required" .Values.frappe.image.tag) -}}
{{- end -}}

{{- define "grievance.labels" -}}
app.kubernetes.io/name: oan-grievance-service
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Values the upstream chart cannot see (a subchart never reads its parent's values) are
duplicated under `frappe`. Fail early when the copies disagree or are missing.
*/}}
{{- define "grievance.validate" -}}
{{- $site := required "siteName is required" .Values.siteName -}}
{{- if ne $site .Values.frappe.jobs.createSite.siteName -}}
{{- fail "frappe.jobs.createSite.siteName must equal siteName" -}}
{{- end -}}
{{- if .Values.frappe.jobs.migrate.enabled -}}
{{- fail "keep frappe.jobs.migrate disabled: the site-config job runs bench migrate after the site exists" -}}
{{- end -}}
{{- if not (or (index .Values.frappe "mariadb-sts").enabled .Values.frappe.dbHost) -}}
{{- fail "set frappe.dbHost (external MariaDB) or enable frappe.mariadb-sts" -}}
{{- end -}}
{{- end -}}

{{/* grievanceQueues as the `workers` object of common_site_config.json. */}}
{{- define "grievance.workersConf" -}}
{{- $workers := dict -}}
{{- range $queue, $timeout := .Values.grievanceQueues -}}
{{- $_ := set $workers $queue (dict "timeout" $timeout) -}}
{{- end -}}
{{- toJson $workers -}}
{{- end -}}
