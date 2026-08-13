{{- define "teranode-bridge.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "teranode-bridge.fullname" -}}
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

{{- define "teranode-bridge.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "teranode-bridge.labels" -}}
helm.sh/chart: {{ include "teranode-bridge.chart" . }}
{{ include "teranode-bridge.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: bsv-multicast
app.kubernetes.io/component: {{ .Values.config.mode | default "all" }}
{{- end -}}

{{- define "teranode-bridge.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teranode-bridge.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "teranode-bridge.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "teranode-bridge.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
port — the port a listen address binds, so containerPort/Service port can never
drift from the flag the process actually gets. Input is the raw listen string
("[::]:8833", "192.0.2.10:9145", ":9146"); output is the trailing number.
*/}}
{{- define "teranode-bridge.port" -}}
{{- $addr := . | toString -}}
{{- $p := regexFind "[0-9]+$" $addr -}}
{{- if not $p -}}
{{- fail (printf "teranode-bridge: cannot derive a port from listen address %q — it must end in :<port>" $addr) -}}
{{- end -}}
{{- $p -}}
{{- end -}}

{{/*
apiPrefix / announceUrl — the URL the cluster is told to pull from, built the
same way the binary builds it: TrimRight(advertise, "/") + "/" + trim(prefix).
This is the value that silently breaks subtree and block ingest when wrong, so
NOTES.txt prints it and validate rejects the doubled form.
*/}}
{{- define "teranode-bridge.apiPrefix" -}}
{{- printf "/%s" (trimAll "/" (.Values.config.apiPrefix | default "/api/v1")) -}}
{{- end -}}

{{- define "teranode-bridge.announceUrl" -}}
{{- printf "%s%s" (trimSuffix "/" (.Values.config.advertise | default "")) (include "teranode-bridge.apiPrefix" .) -}}
{{- end -}}

{{/*
validate — install-time refusal for configurations that are wrong in a way the
running process would not tell you about (or would only tell you by exiting 2
into a crashloop). Warnings, not failures, live in NOTES.txt.
*/}}
{{- define "teranode-bridge.validate" -}}
{{- $c := .Values.config -}}
{{- $sink := eq ($c.mode | default "all") "sink" -}}
{{- $adv := trimSuffix "/" ($c.advertise | default "") -}}
{{- $prefix := include "teranode-bridge.apiPrefix" . -}}
{{- if and $adv (hasSuffix $prefix $adv) -}}
{{- fail (printf "teranode-bridge: config.advertise (%q) already ends with config.apiPrefix (%q). The announced URL is advertise + apiPrefix, so this announces %q — the cluster's subtree and block pulls would 404 against a doubled path while every announcement kept succeeding. Drop the prefix from config.advertise." $adv $prefix (printf "%s%s" $adv $prefix)) -}}
{{- end -}}
{{- if and (not $sink) (or $c.kafka $c.subtreeTopic) (not $c.peerId) -}}
{{- fail "teranode-bridge: config.peerId is empty while announcements are configured. Empty is UNSAFE: the cluster's catchup substitutes the announce URL for a missing peer id, targets this bridge's retrieval plane for the header chain, 404s, and circuit-breaks itself out of recovery (verified live at teranode 1cca625 — a node wedged 300+ blocks behind a healthy peer). Set config.peerId to a SYNTHETIC valid-format libp2p id (12D3KooW…) derived from a fresh ed25519 key and registered nowhere: the catchup gate then diverts chain sync to real libp2p peers while every delivery gate (bans only) keeps pulling objects from the bridge. Give each bridge instance its own id and never reuse a real peer's." -}}
{{- end -}}
{{- if and $c.peerId (not (regexMatch "^12D3KooW[1-9A-HJ-NP-Za-km-z]{44}$" $c.peerId)) -}}
{{- fail (printf "teranode-bridge: config.peerId (%q) is not a valid-format ed25519 libp2p peer id (12D3KooW + 44 base58 chars). An undecodable id is diverted for the wrong reason and pollutes the cluster's logs with decode errors; derive a real one: ed25519 pub -> protobuf 08011220||pub -> multihash 0024||… -> base58btc." $c.peerId) -}}
{{- end -}}
{{- if and (not $sink) $c.blockchain -}}
{{- if or (not $c.localAsset) (not $c.edgeIngress) -}}
{{- fail "teranode-bridge: config.blockchain enables the reverse path, which also requires config.localAsset and config.edgeIngress. The binary exits 2 on the incomplete set, so this would be a crashloop rather than a running bridge." -}}
{{- end -}}
{{- if and $c.submitter (gt (int .Values.replicaCount) 1) -}}
{{- fail (printf "teranode-bridge: replicaCount is %d with the reverse path enabled and config.submitter true. Exactly ONE bridge per class per cluster may hold the submitter role — %d of them would publish every locally produced subtree and block onto the object plane %d times over. Run the submitter as its own single-replica release and set config.submitter=false on any scaled-out pull tier (which stays a hot spare: promotion is a flag flip and a restart)." (int .Values.replicaCount) (int .Values.replicaCount) (int .Values.replicaCount)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
flag — render one CLI flag from a values key.
  bool true            -> "-name"        (bare)
  bool false / null    -> omitted        (binary default applies)
  "" / "0s" / 0        -> omitted        (binary default applies)
  anything else        -> "-name=value"
Flags whose ZERO VALUE MEANS SOMETHING cannot go through here — omission would
silently restore the binary's non-zero default. Those are written out
unconditionally in .args below.
*/}}
{{- define "teranode-bridge.flag" -}}
{{- $name := .name -}}
{{- $v := .v -}}
{{- if kindIs "bool" $v -}}
{{- if $v }}
- {{ printf "-%s" $name | quote }}
{{- end -}}
{{- else if kindIs "string" $v -}}
{{- if and (ne $v "") (ne $v "0s") }}
- {{ printf "-%s=%s" $name $v | quote }}
{{- end -}}
{{- else -}}
{{- if and $v (ne (printf "%v" $v) "0") }}
- {{ printf "-%s=%d" $name (int64 $v) | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
listFlag — a repeatable flag, one occurrence per element. The binary also
accepts a comma-separated value, but one flag per endpoint keeps `kubectl
describe pod` readable and keeps `--set` free of comma escaping.
*/}}
{{- define "teranode-bridge.listFlag" -}}
{{- $name := .name -}}
{{- range .v }}
- {{ printf "-%s=%s" $name (. | toString) | quote }}
{{- end -}}
{{- end -}}

{{- define "teranode-bridge.args" -}}
{{- $c := .Values.config -}}
{{- $sink := eq ($c.mode | default "all") "sink" -}}
{{/* Delivery lanes — the only plane a sink runs */}}
{{- include "teranode-bridge.flag" (dict "name" "tx-listen" "v" $c.txListen) -}}
{{- include "teranode-bridge.flag" (dict "name" "subtree-listen" "v" $c.subtreeListen) -}}
{{- include "teranode-bridge.flag" (dict "name" "block-listen" "v" $c.blockListen) -}}
{{- include "teranode-bridge.flag" (dict "name" "max-object" "v" $c.maxObject) -}}
{{- /* mode=sink skips the retrieval plane, both cluster targets and the reverse
       path outright, so the arg vector says so too: a sink that lists an
       -advertise or a -propagation reads like a bridge that lost its cluster. */ -}}
{{- if not $sink -}}
{{/* Retrieval plane */}}
{{- include "teranode-bridge.flag" (dict "name" "retrieval-listen" "v" $c.retrievalListen) -}}
{{- include "teranode-bridge.flag" (dict "name" "advertise" "v" (trimSuffix "/" ($c.advertise | default ""))) -}}
{{- include "teranode-bridge.flag" (dict "name" "api-prefix" "v" $c.apiPrefix) -}}
{{/* Cluster ingest targets */}}
{{- include "teranode-bridge.listFlag" (dict "name" "propagation" "v" $c.propagation) -}}
{{- include "teranode-bridge.listFlag" (dict "name" "kafka" "v" $c.kafka) -}}
{{/* Announcements */}}
{{- include "teranode-bridge.flag" (dict "name" "subtree-topic" "v" $c.subtreeTopic) -}}
{{- include "teranode-bridge.flag" (dict "name" "block-topic" "v" $c.blockTopic) -}}
{{- include "teranode-bridge.flag" (dict "name" "peer-id" "v" $c.peerId) -}}
{{/* Reverse path */}}
{{- include "teranode-bridge.flag" (dict "name" "blockchain" "v" $c.blockchain) -}}
{{- include "teranode-bridge.flag" (dict "name" "local-asset" "v" $c.localAsset) -}}
{{- include "teranode-bridge.flag" (dict "name" "edge-ingress" "v" $c.edgeIngress) -}}
{{- include "teranode-bridge.flag" (dict "name" "edge-subtree-port" "v" $c.edgeSubtreePort) -}}
{{- include "teranode-bridge.flag" (dict "name" "edge-block-port" "v" $c.edgeBlockPort) -}}
{{- include "teranode-bridge.flag" (dict "name" "mine-tag" "v" $c.mineTag) -}}
{{- /* binary default TRUE => always explicit, in both directions */ -}}
{{- $submitter := true -}}
{{- if kindIs "bool" $c.submitter }}{{ $submitter = $c.submitter }}{{ end }}
- {{ printf "-submitter=%v" $submitter | quote }}
{{- end -}}
{{- /* Transaction pipeline */ -}}
{{- include "teranode-bridge.flag" (dict "name" "tx-batch" "v" $c.txBatch) -}}
{{- include "teranode-bridge.flag" (dict "name" "tx-batch-bytes" "v" $c.txBatchBytes) -}}
{{- include "teranode-bridge.flag" (dict "name" "tx-linger" "v" $c.txLinger) -}}
{{- include "teranode-bridge.flag" (dict "name" "tx-inflight" "v" $c.txInflight) -}}
{{- include "teranode-bridge.flag" (dict "name" "tx-builders" "v" $c.txBuilders) -}}
{{- /* 0 = retries OFF; omission would restore the binary's 3 */ -}}
{{- $retries := 3 -}}
{{- if not (kindIs "invalid" $c.txRetries) }}{{ $retries = int64 $c.txRetries }}{{ end }}
- {{ printf "-tx-retries=%d" $retries | quote }}
{{- /* Cache */ -}}
{{- include "teranode-bridge.flag" (dict "name" "cache-bytes" "v" $c.cacheBytes) -}}
{{- include "teranode-bridge.flag" (dict "name" "cache-ttl" "v" $c.cacheTtl) -}}
{{/* Process */}}
{{- include "teranode-bridge.flag" (dict "name" "mode" "v" $c.mode) -}}
{{- /* "0s" = periodic stats OFF; omission would restore the binary's 1m */ -}}
{{- $stats := "1m" -}}
{{- if and (not (kindIs "invalid" $c.statsEvery)) (ne ($c.statsEvery | toString) "") }}{{ $stats = ($c.statsEvery | toString) }}{{ end }}
- {{ printf "-stats-every=%s" $stats | quote }}
{{- /* metrics.enabled false => explicitly empty, the only value that turns the
       listener (and with it /healthz, /readyz, POST /loglevel) off */ -}}
{{- if .Values.metrics.enabled }}
- {{ printf "-metrics-addr=%s" ($c.metricsAddr | default "[::]:9146") | quote }}
{{- else }}
- "-metrics-addr="
{{- end }}
{{- include "teranode-bridge.flag" (dict "name" "log-level" "v" $c.logLevel) -}}
{{- include "teranode-bridge.flag" (dict "name" "log-format" "v" $c.logFormat) -}}
{{- include "teranode-bridge.flag" (dict "name" "instance-id" "v" $c.instanceId) -}}
{{- include "teranode-bridge.flag" (dict "name" "debug" "v" $c.debug) -}}
{{- range .Values.extraArgs }}
- {{ . | quote }}
{{- end -}}
{{- end -}}
