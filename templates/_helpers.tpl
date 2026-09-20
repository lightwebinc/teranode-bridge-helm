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
("[::]:8725", "192.0.2.10:9145", ":9146"); output is the trailing number.
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
{{- if .Values.tunnel.enabled -}}
{{- if ne .Values.networking.mode "pod" -}}
{{- fail "teranode-bridge: tunnel.enabled needs networking.mode=pod. The sidecar creates the WireGuard interface in the POD's network namespace, which is what lets the bridge's listeners receive the lanes; under hostNetwork it would create it on the node itself, as root, from a chart. If the tunnel belongs on the node, terminate it there (wg-quick under systemd) and leave tunnel.enabled false." -}}
{{- end -}}
{{- if gt (int .Values.replicaCount) 1 -}}
{{- fail (printf "teranode-bridge: replicaCount is %d with tunnel.enabled. A WireGuard key is ONE session: the edge sends to whichever pod handshook last, so %d pods sharing a key steal the tunnel from each other every keepalive and each sees a fraction of every lane. Run one release per provisioned tunnel." (int .Values.replicaCount) (int .Values.replicaCount)) -}}
{{- end -}}
{{- if not .Values.tunnel.configSecret.name -}}
{{- fail "teranode-bridge: tunnel.enabled needs tunnel.configSecret.name. The wg-quick configuration holds your private key, so the chart only ever reads it from a Secret you create yourself: kubectl create secret generic <name> --from-file=wg0.conf=./wg0.conf" -}}
{{- end -}}
{{- if not (regexMatch "^[a-zA-Z0-9_=+.-]{1,15}$" (.Values.tunnel.interface | default "")) -}}
{{- fail (printf "teranode-bridge: tunnel.interface (%q) is not a valid interface name: 1 to 15 characters of letters, digits and _=+.-" (.Values.tunnel.interface | default "")) -}}
{{- end -}}
{{- if and .Values.tunnel.nativeSidecar (semverCompare "<1.29.0-0" .Capabilities.KubeVersion.Version) -}}
{{- fail (printf "teranode-bridge: tunnel.nativeSidecar needs Kubernetes 1.29 or later (this cluster reports %s). Set tunnel.nativeSidecar=false to run the tunnel as an ordinary container." .Capabilities.KubeVersion.Version) -}}
{{- end -}}
{{- end -}}
{{- $sink := eq ($c.mode | default "all") "sink" -}}
{{- $adv := trimSuffix "/" ($c.advertise | default "") -}}
{{- $prefix := include "teranode-bridge.apiPrefix" . -}}
{{- if and $adv (hasSuffix $prefix $adv) -}}
{{- fail (printf "teranode-bridge: config.advertise (%q) already ends with config.apiPrefix (%q). The announced URL is advertise + apiPrefix, so this announces %q — the cluster's subtree and block pulls would 404 against a doubled path while every announcement kept succeeding. Drop the prefix from config.advertise." $adv $prefix (printf "%s%s" $adv $prefix)) -}}
{{- end -}}
{{- /* Announcements exist only where brokers do: subtreeTopic/blockTopic carry
       non-empty defaults, so they say nothing about whether anything announces. */ -}}
{{- if and (not $sink) $c.kafka (not $c.peerId) -}}
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
{{- /* Cluster-state poll rides the reverse path's blockchain connection, so it
       is only meaningful alongside -blockchain. "0s" turns it off; omission
       would restore the binary's 15s. */ -}}
{{- if $c.blockchain -}}
{{- /* Transport security mirrors the cluster's GLOBAL security_level_grpc; a
       mismatch means the reverse path can never connect while every other plane
       keeps working. Always rendered so the level is visible in the pod spec. */ -}}
{{- $lvl := 0 -}}
{{- if not (kindIs "invalid" $c.blockchainSecurityLevel) }}{{ $lvl = int $c.blockchainSecurityLevel }}{{ end }}
- {{ printf "-blockchain-security-level=%d" $lvl | quote }}
{{- include "teranode-bridge.flag" (dict "name" "blockchain-ca-cert" "v" $c.blockchainCaCert) -}}
{{- include "teranode-bridge.flag" (dict "name" "blockchain-cert" "v" $c.blockchainCert) -}}
{{- include "teranode-bridge.flag" (dict "name" "blockchain-key" "v" $c.blockchainKey) -}}
{{- /* Keepalive: grpc-go pings NEVER by default, so omission is not a benign
       default — it is the wedge. Rendered explicitly in both directions. */ -}}
{{- $ka := "30s" -}}
{{- if and (not (kindIs "invalid" $c.blockchainKeepalive)) (ne ($c.blockchainKeepalive | toString) "") }}{{ $ka = ($c.blockchainKeepalive | toString) }}{{ end }}
- {{ printf "-blockchain-keepalive=%s" $ka | quote }}
{{- $kat := "20s" -}}
{{- if and (not (kindIs "invalid" $c.blockchainKeepaliveTimeout)) (ne ($c.blockchainKeepaliveTimeout | toString) "") }}{{ $kat = ($c.blockchainKeepaliveTimeout | toString) }}{{ end }}
- {{ printf "-blockchain-keepalive-timeout=%s" $kat | quote }}
{{- $kaIdle := true -}}
{{- if kindIs "bool" $c.blockchainKeepaliveWhenIdle }}{{ $kaIdle = $c.blockchainKeepaliveWhenIdle }}{{ end }}
- {{ printf "-blockchain-keepalive-when-idle=%v" $kaIdle | quote }}
{{- $poll := "15s" -}}
{{- if and (not (kindIs "invalid" $c.clusterPoll)) (ne ($c.clusterPoll | toString) "") }}{{ $poll = ($c.clusterPoll | toString) }}{{ end }}
- {{ printf "-cluster-poll=%s" $poll | quote }}
{{- end -}}
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
{{- /* Observability shape. All four have binary defaults that are NOT the
       chart's, or are a migration switch an operator must be able to see in
       `kubectl describe pod`, so every one is rendered explicitly. */ -}}
{{- if .Values.metrics.enabled }}
{{- $legacy := true -}}
{{- if kindIs "bool" .Values.metrics.legacyPrefix }}{{ $legacy = .Values.metrics.legacyPrefix }}{{ end }}
- {{ printf "-metrics-legacy-prefix=%v" $legacy | quote }}
{{- $txHist := false -}}
{{- if kindIs "bool" .Values.metrics.txSizeHistogram }}{{ $txHist = .Values.metrics.txSizeHistogram }}{{ end }}
- {{ printf "-tx-size-histogram=%v" $txHist | quote }}
{{- $strict := false -}}
{{- if kindIs "bool" .Values.health.strict }}{{ $strict = .Values.health.strict }}{{ end }}
- {{ printf "-health-strict=%v" $strict | quote }}
{{- end }}
{{- /* Tracing: off unless asked for, as upstream. */ -}}
{{- if .Values.tracing.enabled }}
- "-tracing-enabled=true"
{{- include "teranode-bridge.flag" (dict "name" "tracing-collector-url" "v" .Values.tracing.collectorUrl) -}}
{{- /* The generic flag helper renders numbers through int64, which would turn
       a 0.01 sample rate into 0 — and 0 is itself a MEANINGFUL rate (sample
       nothing), so it cannot be dropped as a zero value either. Render it
       explicitly, as a float, whenever tracing is on. */ -}}
{{- $rate := 0.01 -}}
{{- if not (kindIs "invalid" .Values.tracing.sampleRate) }}{{ $rate = .Values.tracing.sampleRate }}{{ end }}
- {{ printf "-tracing-sample-rate=%v" $rate | quote }}
{{- end }}
{{- /* Profiling rates. Zero is the binary default and renders nothing. */ -}}
{{- include "teranode-bridge.flag" (dict "name" "block-profile-rate" "v" .Values.profiling.blockProfileRate) -}}
{{- include "teranode-bridge.flag" (dict "name" "mutex-profile-fraction" "v" .Values.profiling.mutexProfileFraction) -}}
{{- include "teranode-bridge.flag" (dict "name" "log-level" "v" $c.logLevel) -}}
{{- include "teranode-bridge.flag" (dict "name" "log-format" "v" $c.logFormat) -}}
{{- include "teranode-bridge.flag" (dict "name" "instance-id" "v" $c.instanceId) -}}
{{- include "teranode-bridge.flag" (dict "name" "debug" "v" $c.debug) -}}
{{- range .Values.extraArgs }}
- {{ . | quote }}
{{- end -}}
{{- end -}}


{{/*
tunnelScript — what the WireGuard sidecar runs. The provisioned wg-quick file
is copied out of the Secret into a tmpfs (mode 0600, named after the
interface, which is what wg-quick requires) with two edits: a DNS= line is
dropped, because the pod keeps the cluster's resolver and wg-quick would
otherwise want resolvconf and a writable /etc; and an MTU is written when the
file carries none.

It refuses two configurations outright, because both fail silently later:
  * the unedited "PrivateKey = <paste ...>" placeholder
  * a default route in AllowedIPs, which would pull the bridge's own traffic
    to Kafka, propagation and the asset service into the tunnel

The pod's network namespace outlives a container restart, so an interface left
behind by a killed sidecar is removed before bringing the tunnel up.
*/}}
{{- define "teranode-bridge.tunnelScript" -}}
{{- $t := .Values.tunnel -}}
set -euo pipefail
IFACE={{ $t.interface | quote }}
SRC="/etc/wireguard-secret/{{ $t.configSecret.key }}"
CONF="/run/wireguard/${IFACE}.conf"
say() { echo "tunnel: $*" >&2; }

[ -s "$SRC" ] || { say "$SRC is missing or empty: check tunnel.configSecret.name and .key"; exit 1; }
if grep -Eiq '^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*(<|$)' "$SRC"; then
  say "PrivateKey is still the placeholder. Paste the PRIVATE key you generated (never the public one) and recreate the Secret."
  exit 1
fi
if grep -Ei '^[[:space:]]*AllowedIPs[[:space:]]*=' "$SRC" | grep -Eq '(=|,)[[:space:]]*(0\.0\.0\.0|::)/0[[:space:]]*(,|$)'; then
  say "AllowedIPs contains a default route. In a pod that sends the bridge's own traffic (Kafka, propagation, asset) into the tunnel. Use the prefixes from your provisioned configuration."
  exit 1
fi

umask 077
grep -Eiv '^[[:space:]]*DNS[[:space:]]*=' "$SRC" > "$CONF.tmp"
{{- if gt (int $t.mtu) 0 }}
if ! grep -Eiq '^[[:space:]]*MTU[[:space:]]*=' "$CONF.tmp"; then
  awk -v mtu={{ int $t.mtu }} '{ print } /^\[Interface\]/ && !done { print "MTU = " mtu; done = 1 }' "$CONF.tmp" > "$CONF.tmp2"
  mv "$CONF.tmp2" "$CONF.tmp"
fi
{{- end }}
mv "$CONF.tmp" "$CONF"

down() {
{{- if not $t.nativeSidecar }}
  say "SIGTERM: holding the tunnel up {{ int $t.shutdownDelaySeconds }}s so the bridge can drain its lanes"
  sleep {{ int $t.shutdownDelaySeconds }} || true
{{- end }}
  wg-quick down "$CONF" || true
  exit 0
}
trap down TERM INT

ip link del dev "$IFACE" 2>/dev/null || true
wg-quick up "$CONF"
say "up: $(wg show "$IFACE" public-key), $(wg show "$IFACE" peers | wc -l) peer(s), listening for handshakes"
while :; do sleep 3600 & wait $!; done
{{- end -}}

{{/*
tunnelContainer — the sidecar itself. Rendered under initContainers with
restartPolicy: Always (a native sidecar) or under containers, by the caller.
*/}}
{{- define "teranode-bridge.tunnelContainer" -}}
{{- $t := .Values.tunnel -}}
- name: wireguard
  image: "{{ $t.image.repository }}:{{ $t.image.tag }}"
  imagePullPolicy: {{ $t.image.pullPolicy }}
  {{- if $t.nativeSidecar }}
  restartPolicy: Always
  {{- end }}
  {{- with $t.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  command: ["/bin/bash", "-c"]
  args:
    - |
      {{- include "teranode-bridge.tunnelScript" . | nindent 6 }}
  {{- if or $t.userspace $t.extraEnv }}
  env:
    {{- if $t.userspace }}
    - name: WG_QUICK_USERSPACE_IMPLEMENTATION
      value: wireguard-go
    - name: WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD
      value: "1"
    {{- end }}
    {{- with $t.extraEnv }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- if $t.livenessProbe.enabled }}
  livenessProbe:
    exec:
      command:
        - /bin/sh
        - -c
        - >-
          last=$(wg show {{ $t.interface }} latest-handshakes | awk '$2 > m { m = $2 } END { print m + 0 }');
          [ "$last" -gt 0 ] && [ $(( $(date +%s) - last )) -lt {{ int $t.livenessProbe.maxHandshakeAgeSeconds }} ]
    initialDelaySeconds: {{ $t.livenessProbe.initialDelaySeconds }}
    periodSeconds: {{ $t.livenessProbe.periodSeconds }}
    timeoutSeconds: {{ $t.livenessProbe.timeoutSeconds }}
    failureThreshold: {{ $t.livenessProbe.failureThreshold }}
  {{- end }}
  {{- with $t.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: wireguard-secret
      mountPath: /etc/wireguard-secret
      readOnly: true
    - name: wireguard-run
      mountPath: /run/wireguard
    {{- if $t.userspace }}
    - name: dev-net-tun
      mountPath: /dev/net/tun
    {{- end }}
{{- end -}}
