# ADR-0007: Exporter behaviour

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0004 (model), ADR-0006 (ClusterState), ADR-0001 (pipeline)

## Context

BeamScope integrates with the observability ecosystem *rather than replacing it* — it must feed
Prometheus, OpenTelemetry, and Phoenix LiveDashboard from the same runtime model. The risk is that
each integration grows its own state, its own view of the cluster, or a back-channel into the model,
turning clean adapters into a tangle. The pipeline (ADR-0001) already mandates one-way flow ending
at exporters; this ADR pins down what an exporter *is*.

## Decision

**Exporters are stateless adapters defined by `BeamScope.Exporter`; they read the cluster model and
emit it downstream, and never write back.**

```elixir
@callback export(cluster_state :: term()) :: :ok
```

- An exporter receives (or reads) a consistent view of `BeamScope.ClusterState` (ADR-0006) and maps
  the runtime object model (ADR-0004) into a target format. It holds **no authoritative state** and
  has **no side effects on the model** — it is a pure projection at the edge.
- Exporters are **leaves**: they are the terminal pipeline stage and never feed the aggregation or
  synchronization layers.
- Exporters are **feature-toggled via config** (the standalone endpoint by the presence of
  `config :beam_scope, exporter: [port: N]`) and supervised under
  `BeamScope.Exporters.Supervisor`; enabling or removing one cannot affect the model or other
  exporters.
- **MVP exporters (Inc 4, implemented):**
  - **Prometheus** — render the cluster model to Prometheus text exposition **at scrape time**,
    directly from `ClusterState`, every series labelled by `node`. Chosen over
    `telemetry_metrics_prometheus`: a stateful last-value reporter would keep exporting a departed
    node's series indefinitely, whereas scrape-time rendering reflects node expiry for free and is a
    truly stateless read of the model.
  - **Dashboard** — a small, self-contained, auto-refreshing **HTML page** rendered from
    `ClusterState`, so human consumption needs no Phoenix/LiveView dependency in the core. (A
    LiveDashboard page / LiveView remains a natural *future* exporter — just another adapter.)
  - Both are pure `render/1` functions (dependency-free, unit-tested) exposed through a `Plug`
    (`BeamScope.Exporter.Router`); an optional Bandit endpoint serves them standalone, or a host
    mounts the router in its own stack. This is the push-vs-pull wiring difference noted below:
    these are **pull** exporters, so the `Plug`/`render` seam replaces `export/1`.
- **OpenTelemetry is "just another exporter,"** added immediately after MVP. Because it is an
  exporter and not an architectural concern, it needs no core change — the strongest validation that
  this boundary is right.

## Consequences

### Positive
- Adding an ecosystem integration is small, isolated, and low-risk — implement `export/1`, toggle it
  on. This is what lets BeamScope *integrate rather than replace*.
- Statelessness makes exporters trivially testable against a fixed `ClusterState` fixture and safe to
  run many of concurrently.
- The model↔export separation means changing a backend never perturbs the runtime model.

### Negative / costs
- Some duplication of mapping logic across exporters (model→Prometheus, model→OTel, model→UI); we
  accept it in exchange for independence, and can factor shared mapping helpers if it grows.
- Exporters that expect a *stream* (push-based OTel) vs. *pull* (Prometheus scrape) need slightly
  different wiring around the same `export/1` seam; handled per exporter, not in the core.

## Alternatives considered

- **Let exporters read ETS / aggregation directly.** Rejected: couples them to a single node's view
  and to storage internals, defeating the cluster model and ADR-0006's abstraction.
- **Stateful exporters that cache/derive their own cluster view.** Rejected: duplicates
  `ClusterState`, risks divergence, and reintroduces the "monitoring database" anti-goal.
- **A single mega-exporter with pluggable backends.** Rejected: less composable than independent,
  individually-toggleable adapters; the behaviour + supervisor gives the same reuse without coupling.

## Failure modes & CAP

Exporters are read-only leaves, so a failing exporter can never corrupt or block the model — its
supervisor restarts it, and other exporters and the pipeline are unaffected. Because it projects
whatever `ClusterState` currently holds, an exporter naturally surfaces the AP reality (stale/expired
nodes appear as such, per ADR-0004/0005) rather than hiding it.
