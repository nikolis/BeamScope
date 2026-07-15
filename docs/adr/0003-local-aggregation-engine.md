# ADR-0003: Local aggregation engine

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0001 (pipeline), ADR-0002 (embedded), ADR-0004 (model), ADR-0005 (sync)

## Context

Telemetry on the BEAM is high-frequency and bursty: a busy Phoenix or Broadway node can emit tens
of thousands of events per second. BeamScope runs *inside* that node (ADR-0002), so its aggregation
must be effectively free on the hot path — it cannot add contention to the application it observes,
and it must never let event volume translate into network volume (ADR-0001).

The host codebases already contain the pattern to emulate: `crypto_pipe`'s `Metrics` module keeps
a lock-free `:counters` array in `:persistent_term` (`crypto_pipe/lib/crypto_pipe/metrics.ex`),
and both `MarketBoard` and `file_swarm`'s `Tracker` decouple UI/render rate from the event firehose
by folding events into in-memory state and emitting periodic snapshots.

## Decision

**Each domain provider (ADR-0008) folds raw telemetry into a bounded, lock-free local accumulator,
and a periodic tick materializes a compact, versioned snapshot.**

- **Hot path:** write to **ETS tables created with `:write_concurrency`** and/or **`:counters` +
  `:persistent_term`** for pure counters. Telemetry handlers do the minimum possible work — an
  increment or a bounded update — and return. No `GenServer.call`, no cross-node calls, no
  unbounded growth.
- **Batching tick:** on a configurable interval (default `sync_interval`, 1 s) an aggregator reads
  its ETS/counter state, folds it into the provider's runtime-model entities (ADR-0004), stamps a
  **monotonic version + wall-clock timestamp**, and hands the result to `ClusterState` and, via it,
  to synchronization (ADR-0005).
- **Snapshots are compact and bounded in size** — summaries and top-N, never per-event rows — so
  network cost is a function of *node count × snapshot size*, independent of event frequency.
- **Render/sync rate is decoupled from event rate.** Exporters and peers see snapshots at the tick
  cadence; the firehose stays local.

## Consequences

### Positive
- Constant, predictable overhead on the observed application; no lock contention from BeamScope.
- Network and CPU cost scale with cluster size and tick rate, not traffic — the property that makes
  cluster-wide observability affordable.
- Directly reuses a proven, in-house pattern, lowering implementation risk.

### Negative / costs
- Aggregation is **lossy by design**: sub-tick spikes are summarized, not preserved. This is the
  correct trade for a *runtime model* but means BeamScope is not a high-fidelity event tracer.
- Tick interval is a tuning knob trading freshness against overhead; a sensible default plus
  per-provider override is required.
- ETS/counter state must be strictly bounded (top-N, fixed cardinality) or a pathological workload
  could grow memory — a benchmarking and back-pressure concern (ADR roadmap, Inc 5).

## Alternatives considered

- **Forward raw telemetry to a per-node GenServer and aggregate there.** Rejected: a single
  mailbox becomes a contention point and a back-pressure hazard under load; ETS/counters let
  producers write concurrently without a coordinator.
- **`telemetry_metrics` reporters as the aggregation layer.** Rejected as the *core*:
  `Telemetry.Metrics` is excellent for the *export* edge (ADR-0007) but models flat metrics, not
  the rich runtime object model BeamScope must build (ADR-0004). We use it downstream, not as the
  aggregator.
- **Aggregate on read (compute snapshots lazily when queried).** Rejected: makes cost depend on
  query/scrape patterns and complicates synchronization, which needs a steady snapshot stream.

## Failure modes & CAP

Aggregation is entirely node-local, so it introduces no cross-node coupling and no CAP tension of
its own. If a provider's aggregator crashes, its supervisor restarts it with a fresh accumulator
(a brief gap in that domain's snapshots, self-healing on the next tick). Bounded ETS/counter state
ensures a hostile workload degrades snapshot richness, never node liveness.
