# ADR-0010: Bounded "notable requests" for the Phoenix domain

- **Status:** Accepted — 2026-07-22
- **Deciders:** Project architect
- **Related:** ADR-0001 (observations not data), ADR-0003 (aggregation), ADR-0004 (model),
  ADR-0005 (synchronization), ADR-0007 (exporters), ADR-0008 (providers)

## Context

The Phoenix provider (ADR-0008) reports a purely *aggregate* HTTP view per node — windowed
request/error counts, `error_rate`, `avg_latency_ms`, a latency histogram, and a status-class
distribution, plus monotonic `requests_total`/`errors_total`. Operators have asked to also
**investigate individual requests** — to see which specific requests were slow or returned 5xx.

Taken literally ("explore a specific request, with route, params, and stacktrace"), that is
**distributed tracing / APM**: per-event records, retained and queryable. It is the exact thing
ADR-0001 refuses — "synchronize *observations*, not replicate *data*"; "raw telemetry is never
propagated between nodes" — and ADR-0003's "summaries and top-N, **never per-event rows**." It would
also re-couple snapshot size (and thus O(N²) gossip, ADR-0005) to request volume, and push
unbounded-cardinality paths and PII-bearing payloads through gossip *and* the scrape/dashboard
surfaces. That feature belongs **outside** BeamScope, composed alongside it via OpenTelemetry
traces (`opentelemetry_phoenix`), which taps Phoenix telemetry directly and has a backend built for
retention, search, and global ordering.

But a **narrower** reading is on-brand: a small, bounded *sample* of "notable requests this window"
— a **signpost** that tells an operator *where* to look (which route, which node), after which they
hand off to their tracer. This is the same shape as the top-N collections BeamScope already
gossips (`ProcessSummary.top_mailboxes`/`top_memory`, `ETS.largest`, ADR-0004): a bounded summary of
observations, not an event store. This ADR defines that bounded slice and draws the bright line
against the APM feature.

## Decision

**Add a bounded, window-scoped, PII-free sample of notable requests as additional fields on the
existing `%BeamScope.Phoenix{}` entity — a summary of observations, not a request store.**

### Model

Two bounded top-N lists on `%BeamScope.Phoenix{}`, sized by the existing `config :beam_scope,
:top_n` (default 5), each holding thin `BeamScope.Phoenix.NotableRequest` structs:

- `top_slow` — the N highest-latency requests observed in the window.
- `recent_5xx` — the N most recent 5xx / endpoint-exception requests in the window.

```elixir
%BeamScope.Phoenix.NotableRequest{
  route: "/users/:id",   # compiled route TEMPLATE, never the concrete path
  status: 503,
  latency_ms: 1240,
  at: 1_753_142_400_000  # wall-clock ms, display/ordering metadata only (ADR-0005)
}
```

### Rules (non-negotiable — they are what keep this an *observation*)

1. **Bounded.** Both lists are fixed-size (`top_n`); their size cannot grow with load. `aggregate/4`
   keeps them lock-free and bounded on the hot path (ADR-0003).
2. **Thin, PII-free fields only.** Route *template* (bounded by the router), status, latency,
   timestamp — and at most a truncated exception *class/message*. **No concrete paths, no params, no
   headers, no full stacktrace** ever enter the gossiped/scraped struct.
3. **Window-scoped, lossy sample — not a record.** Each tick's snapshot carries only that window's
   notable set; per-node LWW (ADR-0004/0006) overwrites the previous one. Sub-tick and beyond-N
   requests are dropped, and a restart clears the accumulator (ADR-0003). It is documented as a
   sample, never an audit log or a complete 5xx list.
4. **No lookup-by-id, no cross-window history, no retention.** The instant a consumer needs "find
   request abc123", "all requests matching X", or per-request bodies, that is the tracer's job
   (see Alternatives). BeamScope does not answer it.
5. **Per-node LWW unchanged; cluster composition happens at read time.** This is BeamScope's first
   *sample-based* field, but it introduces **no new `ClusterState` merge semantics**: each node
   carries only its own top-N, merged per-node LWW like everything else. A cluster-wide "slowest
   across the fleet" view is produced by an **exporter/API** concatenating per-node lists and
   re-sorting *at read time* — never by a special merge inside `ClusterState` (ADR-0006 stays
   intact). Consumers accept that the composed set is eventually-consistent and may transiently
   differ between viewers.
6. **Additive, zero core change.** Extra fields on `%BeamScope.Phoenix{}`, populated by the existing
   Phoenix provider from the same `[:phoenix, :endpoint, :stop | :exception]` telemetry. No new
   pipeline stage, no core change (ADR-0008).

### Optional future drill-in (not part of this ADR's commitment)

If richer per-request detail is ever wanted, it must follow the split: **gossip only the thin
pointer above; pull the heavy detail node-local via `:erpc`** from the one owning node on demand
(the RPC-pull path ADR-0005 keeps viable). Heavy detail is never gossiped and never entered into a
snapshot. This is called out so the boundary is explicit, not to schedule it.

## Consequences

### Positive

- Answers the *fleet-model* question ("which route/node is hot?") without pretending to answer the
  *APM* question ("why did this request fail?") — staying inside BeamScope's identity (ADR-0001).
- Reuses the established bounded top-N precedent, `top_n` config, and the existing Phoenix telemetry
  and tick path — a self-contained, additive unit of work (ADR-0008).
- Snapshot cost grows by a fixed, small increment (≈`2 × top_n` thin structs), independent of
  request volume — the ADR-0003 property is preserved.

### Negative / costs

- It is a *lossy* signal; users must be told, in docs and field naming, that it is a sample, or they
  will wrongly trust it as a complete error record.
- Even thin route templates are higher-cardinality than the current status-class/latency-bucket
  fields; exporters must render them without turning them into unbounded Prometheus label sets (the
  dashboard/API are the natural surface; a Prometheus family per route is explicitly out).
- Read-time cross-node composition adds a small amount of logic to whichever exporter/API surfaces
  the fleet-wide view — deliberately outside `ClusterState`.

## Alternatives considered

- **Full per-request investigation (params, stacktrace, lookup-by-id) inside BeamScope.** Rejected:
  it is APM/tracing — per-event, retained, PII-bearing — and violates ADR-0001 ("observations not
  data"), ADR-0003 (no per-event rows), and the ADR-0005 cost model. It composes *alongside*
  BeamScope via OpenTelemetry traces / `opentelemetry_phoenix`, which instrument Phoenix telemetry
  directly.
- **Route it through the planned OpenTelemetry *exporter* (ADR-0007 menu).** Rejected as the home
  for this: that exporter maps the aggregate object model → OTLP **metrics**, reading `ClusterState`,
  which by design holds no raw events to build spans from. Traces must be sourced by direct Phoenix
  instrumentation, not downstream of BeamScope's pipeline.
- **A separate `NotableRequest` entity type in the `:phoenix` domain list.** Rejected for now:
  mixing entity types in one `domain => [structs]` list complicates every reader (e.g. the
  dashboard's `first(node, :phoenix)`); bounded fields on the single Phoenix entity match the
  `ProcessSummary`/`ETS` precedent and keep readers simple.
- **Gossip the heavy detail directly at small N.** Rejected: even a handful of stacktraces/param
  maps bloats every snapshot and sprays PII across the whole mesh; heavy detail is node-local
  pull-on-demand or nothing.

## Failure modes & CAP

The field is passive, bounded, node-local data, so it inherits the pipeline's AP behavior with no
new coupling: it merges per-node LWW like every other observation, a restart simply empties it until
the next window, and an unreachable node's notable set is absent (degraded *visibility*, not
liveness) — and any future `:erpc` drill-in to a partitioned node fails closed, consistent with
ADR-0005. Because cross-node composition is read-time only, it adds no synchronous cross-node
dependency to the hot path.
