# teranode-bridge Helm chart

> Part of the [**BSV Layered Multicast**](https://github.com/lightwebinc/bsv-multicast) open-source project — see the main repository for the full architecture, design docs, and BRC specifications.

Helm chart for [teranode-bridge](https://github.com/lightwebinc/teranode-bridge) — the landing-tier shim for pushed delivery into an **unmodified** Teranode cluster.

This repository packages templates, default values, JSON Schema validation, and CI workflows for the bridge. The application source lives in [`teranode-bridge`](https://github.com/lightwebinc/teranode-bridge).

The binary is configured by **CLI flags only** — no environment fallback, no config file — so the Deployment renders `args:` from `.config` in [`values.yaml`](values.yaml). Empty / `0` / `"0s"` / `false` values are omitted so the binary default applies; anything unmodelled goes in `extraArgs`.

## What it deploys

| Plane | Port (default) | Who dials it |
|---|---|---|
| tx lane (BRC-30 EF) | `8833` | the delivery side |
| subtree lane (BRC-143) | `9143` | the delivery side |
| block lane (BRC-144) | `9144` | the delivery side |
| retrieval plane | `9145` | **the Teranode cluster**, pulling what was announced |
| metrics / health | `9146` | Prometheus, kubelet |
| reverse path (out) | `8726` / `8727` | this bridge → object-plane ingress |

The tx lane carries **BRC-30 extended format only**. A BRC-12 standard
transaction parses perfectly well, so the lane checks the EF marker itself and
refuses it on arrival — counted in `btb_lane_objects_rejected_total{lane="tx"}`,
connection kept. Deferring that to the cluster's 4xx would be worse than late:
both serializations share one txid, so the refused copy would first claim the
dedupe entry and suppress the EF copy behind it.

Two Services, because the two directions have different callers: `<release>-teranode-bridge` carries the delivery lanes plus metrics, and `<release>-teranode-bridge-retrieval` is the cluster-facing pull address (not rendered in `sink` mode, which serves no pulls). Service and container ports are **derived from the `config.*Listen` flags**, so a port can never drift from what the process actually binds.

No ConfigMap: there is nothing to mount — the flags are the entire configuration surface.

## Install

> The chart references `ghcr.io/lightwebinc/teranode-bridge:<appVersion>` — `appVersion` always tracks a published image tag (see the contract note in [`Chart.yaml`](Chart.yaml)). The image is public.

```bash
# OCI registry — minimum viable delivery-only bridge
helm install bridge oci://ghcr.io/lightwebinc/charts/teranode-bridge \
  --version 0.3.0 -n bsv-mcast --create-namespace \
  --set config.advertise=http://[2001:db8:3f::1]:9145 \
  --set config.propagation[0]=http://192.0.2.10:20833 \
  --set config.kafka[0]=192.0.2.10:19092 \
  --set config.peerId=12D3KooW…   # synthetic id, registered with no p2p service

# Or from a local clone — landing tier in front of a cluster, both directions
helm install bridge . -n bsv-mcast -f examples/landing-tier.yaml \
  --set config.advertise=http://[2001:db8:3f::1]:9145

# Sink — burn in a delivery slot with no cluster at all
helm install burn-in . -n bsv-mcast -f examples/sink.yaml
```

`helm install` prints the exact URL that will be announced, the state of the reverse path, and a warning for every required flag left empty. Read it.

## `config.advertise` — the one value that fails silently

`-advertise` is the base URL **the cluster** dials to pull an announced subtree or block. Everything else in the ingest path can be verified by watching a counter; this one cannot, because a wrong value breaks nothing that reports an error:

> announcements keep succeeding · pulls never arrive · `retrieval stats` stays flat while `announce stats` climbs · no log line, no failed metric

Rules:

| Rule | Why |
|---|---|
| It is what the **cluster** can dial | Not necessarily what the bridge binds. Binding `[::]:9145` and advertising a routable address is the normal shape. |
| **No API prefix** | The announced URL is `advertise` + `config.apiPrefix`. Putting `/api/v1` in both doubles the path and every subtree/block pull 404s — the chart **refuses to install** that. |
| No trailing slash | Trimmed anyway, but `//subtree/` is what a raw concatenation would produce. |
| Scheme required (`http://`, `https://`) | Schema-enforced: a bare `host:port` is not a URL the cluster can dial. |
| Reachable **from the cluster's LAN** | The cluster is usually not in this k8s cluster. A pod-DNS name only works if it resolves there; otherwise use `networking.mode: host` and a node address, or a LoadBalancer address on `service.retrieval`. |

`config.localAsset` is the mirror image and the easy thing to get backwards: it **does** carry the cluster's own `/api/v1`, because the bridge dials it exactly as given.

## Modes

| `config.mode` | What runs | Required |
|---|---|---|
| `all` (default) | lanes + propagation submit + Kafka announce + retrieval plane (+ reverse path if `config.blockchain` is set) | `advertise`, `propagation`, `kafka` |
| `sink` | lanes only: receive, parse, verify, count | **nothing** |

`sink` is a first-class deployment, not a degraded one: the lanes still run and still enforce framing, so it burns in a delivery slot before a cluster exists and separates object-plane faults from cluster-side ones. The chart drops the cluster-facing flags and the retrieval Service entirely in that mode — a sink that listed an `-advertise` would read like a bridge that lost its cluster.

## Scaling — why `replicaCount` stays 1

Two properties make replicas the wrong instrument:

1. **The object cache is in-process, and each bridge announces itself.** A pushed subtree lives only on the bridge that received it. Put N replicas behind one Service and `(N-1)/N` of the cluster's pulls land on a replica that never saw the object: `404`, and the cluster falls back to its ordinary peer announce-and-pull (slower, not lost). The chart warns on `replicaCount > 1`.
2. **Exactly one submitter per class per cluster.** `-submitter` decides whether this bridge publishes what the cluster produced back onto the object plane. Two holders publish every local subtree and block twice. The chart **fails the install** for `replicaCount > 1` while the reverse path is enabled and `config.submitter` is true, rather than silently creating N submitters.

Scale by adding **releases**, each with its own `config.advertise` — see [`examples/standby.yaml`](examples/standby.yaml). A second bridge with `config.submitter: false` still connects and still runs its origin filter (`remote_skipped` keeps counting) but publishes nothing: a hot spare whose promotion is a flag flip and a restart.

For the same reason the chart ships **no HorizontalPodAutoscaler**. Autoscaling this workload would fragment the cache under load — the moment it is least able to absorb a miss — and, with the reverse path on, would be scaling the one thing that must stay singular.

## Install-time refusals

The chart fails rather than render a manifest that produces a crashloop or a silent data fault:

| Condition | Why not a warning |
|---|---|
| `config.advertise` ends with `config.apiPrefix` | Doubled announce path. Nothing errors at runtime; subtree and block ingest simply stops. |
| `config.peerId` empty while announcements are configured | Catchup substitutes the announce URL for the missing id, targets the bridge for the header chain, `404`s, and circuit-breaks the cluster out of recovery. |
| `config.peerId` not `12D3KooW` + 44 base58 chars | An undecodable id is diverted for the wrong reason and fills the cluster's logs with decode errors. |
| `config.blockchain` set without `config.localAsset` **and** `config.edgeIngress` | The binary exits `2` before any listener opens — a crashloop, not a bridge. |
| `replicaCount > 1` with reverse path + `config.submitter: true` | Duplicate upward publication of every locally produced object. |

Softer problems (empty `advertise`/`propagation`/`kafka`, an empty `mineTag` with the reverse path on, `replicaCount > 1`) surface as NOTES warnings and a `helm.sh/chart-warnings` pod annotation.

## Values reference

See [`values.yaml`](values.yaml) for the full annotated reference — every flag in [`teranode-bridge/docs/configuration.md`](https://github.com/lightwebinc/teranode-bridge/blob/main/docs/configuration.md) is reachable from `.config`, except the standby-promotion trio (`-submitter-probe`, `-submitter-grace`, `-submitter-when-blind`), which go through `extraArgs`.

### Flags whose zero value means something

Omission means "use the binary default", so a flag whose default is non-zero can never be turned *off* by omitting it. Four are therefore rendered **unconditionally**:

| Key | Renders | Because |
|---|---|---|
| `config.submitter` | `-submitter=<v>` | Binary default `true`; a bare flag can only turn a role on, so `false` would be a silent no-op. |
| `config.txRetries` | `-tx-retries=<v>` | `0` means *no retries*; omitted it becomes the binary's `3`. |
| `config.statsEvery` | `-stats-every=<v>` | `"0s"` means *no periodic stats*; omitted it becomes the binary's `1m`. |
| `metrics.enabled: false` | `-metrics-addr=` | The only value that switches the listener off. Setting `config.metricsAddr: ""` would be omitted and the binary default `[::]:9146` would apply — metrics you thought you had disabled. |

`metrics.enabled: false` also removes `/healthz`, `/readyz`, `POST /loglevel` and both probes, which have nowhere else to point.

### Networking

| `networking.mode` | Use |
|---|---|
| `pod` (default) | Ordinary CNI. Right when the Teranode cluster and the delivery side can both route to cluster Services. |
| `host` | `hostNetwork: true` — the pod binds node addresses. Right when the cluster can only reach a node address, which is the common case for a landing tier in front of a LAN cluster. Lane ports become **host** ports: one bridge per node, and the rollout defaults to `Recreate` (a rolling update cannot bind the same host ports twice). |

`networkPolicy` splits ingress by audience — `laneIngressFrom` (delivery side), `retrievalIngressFrom` (the cluster), `metricsIngressFrom` (Prometheus) — and is fail-closed: enabling it with an empty list for a port admits no peers on it. It is inert under `networking.mode: host`; restrict host traffic at the node firewall.

### Sizing

`resources` defaults assume the 1 GiB `config.cacheBytes` default. That value is **per cache and there are two** (objects and transactions), so the process ceiling is twice it — raise the memory request/limit and `cacheBytes` together, or the pod is OOM-killed inside the validation window it exists to cover.

Size `config.cacheTtl` against **validation lag** (seconds), not retention. An entry evicted before the cluster pulls it is a `404` and a fallback to the peer path: degraded latency, not lost data. Watch `cache evicted` and `retrieval miss` together — rising miss against flat evicted points at a topic name or `-advertise` problem instead.

### Reverse path

Set `config.blockchain` to enable it; `config.localAsset` and `config.edgeIngress` become mandatory. Two things to get right:

- **`config.mineTag`** — this cluster's `coinbase_arbitrary_text`. Blockchain notifications carry no origin, so a block learned over libp2p *before* the fabric delivered it looks locally produced; without the tag the bridge republishes a remote block upward with false attribution. The check is derived from block content, so it survives the restart that wipes the seen-registry. Needs no Teranode change.
- **The gRPC connection to the blockchain service is plaintext and unauthenticated.** Keep it on a trusted LAN.

## Helm test

```bash
helm test bridge -n bsv-mcast
```

Probes `/healthz`, `/metrics` and `/readyz` on the metrics Service. `/readyz` answers `200` only once **every** lane is bound — the one check that distinguishes a live bridge from a running process.

## Release

The `release.yml` workflow is gated. It runs only via `workflow_dispatch` with `confirm: RELEASE` and a `production` GitHub Environment review. Tag-based auto-release is intentionally disabled.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
