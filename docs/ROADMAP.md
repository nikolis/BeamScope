# BeamScope — Roadmap

## North star

The first release exists to answer **one** question:

> *Is the BeamScope architecture fundamentally sound?*

Not *"does BeamScope support every library?"* — that comes for free once the pipeline is proven,
because every future domain becomes another `DomainProvider` plugin (ADR-0008).

So v1 is a **Vertical Slice MVP**: prove the *entire* pipeline end-to-end on a deliberately tiny
surface, rather than covering any single domain deeply.

```
Telemetry → Local Aggregation (ETS) → Runtime Model → Synchronization
          → Cluster Runtime Model → Exporter
```

If that slice is solid, the platform is real.

## Increments

Each increment is independently reviewable and leaves the project compiling and tested.

### Inc 0 — Scaffold  ✅ (this repository)
- `mix new beam_scope --sup`; deps declared (`telemetry`, `telemetry_poller`, `phoenix_pubsub`;
  `telemetry_metrics` + `telemetry_metrics_prometheus` optional).
- `precommit` alias mirroring the host convention (compile-warnings-as-errors, deps.unlock --unused,
  format, test).
- Behaviours stubbed in `lib/` (`Synchronization`, `DomainProvider`, `Exporter`); public API stubs;
  empty supervision tree. Foundational ADRs + this roadmap.

### Inc 1 — Local core loop (single node)  ✅
- `BeamScope.ClusterState` (ADR-0006): ETS-backed, versioned per-node map, `put_local/merge/get/
  nodes/expire`. Reads hit ETS directly; writes serialize local version assignment.
- `BeamScope.Aggregator` (generic, one per provider) + the **VM** `BeamScope.Provider.VM`
  (`:telemetry_poller`): Telemetry → ETS accumulator → snapshot tick → `ClusterState`.
- `BeamScope.VM` / `BeamScope.ClusterNode` structs; public API `cluster/0`, `nodes/0`, `node/1`,
  `vm/1` wired.
- **Exit criterion — MET:** running the app, `BeamScope.vm(node())` returns a live `%VM{}` with
  memory breakdown, run queue, uptime, and `otp_release`; `uptime_ms` and the node `version` advance
  on each tick. Verified via `mix test` (12 passing) and `mix run`.

> `merge/1` and `expire/2` are implemented but not yet driven cross-node — that wiring is Inc 2.

### Inc 2 — Synchronization  ✅
- `BeamScope.Synchronization` behaviour + default `BeamScope.Synchronization.SnapshotGossip` over
  `Phoenix.PubSub` (ADR-0005): periodic broadcast of the local snapshot, LWW-per-node merge, heartbeat
  TTL sweep, and `:net_kernel` `:nodedown` for prompt expiry.
- Per-node ordering upgraded to an **`{incarnation, version}`** logical clock so a restarted node
  (whose version resets) revives correctly. `ClusterState.expire_node/1` added for `:nodedown`.
- App wiring: optional standalone `Phoenix.PubSub` (`start_pubsub`) for dev; sync starts only when a
  strategy **and** a PubSub server are configured (embedded hosts stay inert until they wire PubSub).
- **Exit criterion — MET:** verified with a live two-node distributed demo — node B saw node A's `VM`
  (`:live`), A being killed aged it `:live → :stale → :expired` on B, and restarting A revived it to
  `:live` (newer incarnation). 19 tests pass (`mix precommit` green), including gossip merge, self-
  ignore, `:nodedown`, and sweep-expiry cases.

### Inc 3 — Remaining MVP providers + full API  ✅
- **Scheduler**, **Processes**, **ETS** providers (`BeamScope.Scheduler` / `ProcessSummary` / `ETS`
  structs, ADR-0004), each a `DomainProvider` added to a **config-driven provider list** with one
  shared `:telemetry_poller` — no core change (ADR-0008). Scheduler utilization is a
  `{active, total}` delta across `:scheduler_wall_time` samples, enabled via a new optional
  `DomainProvider.setup/0`.
- Completed the public API: `schedulers/1`, `processes/1`, `ets/1` (ADR-0009).
- **Aggregator hardening:** traps exits (so `terminate/2` detaches the telemetry handler on
  shutdown) + a per-instance unique handler id, so handlers can't leak across restarts and fire
  against a deleted accumulator.
- **Exit criterion — MET:** `mix precommit` green (29 tests, incl. per-provider + a four-domain
  pipeline test); a live run shows `vm/1`, `schedulers/1` (utilization float in [0,1]),
  `processes/1` (count/limit + top-N), `ets/1` (table count/memory + largest) all populated;
  config toggle verified (VM-only leaves Scheduler absent and `:scheduler_wall_time` disabled).

### Inc 4 — Exporters  ✅
- **Prometheus** — `BeamScope.Exporter.Prometheus` renders the cluster model to text exposition at
  scrape time (node-labelled gauges), directly from `ClusterState` (chosen over
  `telemetry_metrics_prometheus` so departed nodes' series expire correctly; ADR-0007).
- **Dashboard** — `BeamScope.Exporter.Dashboard`, a self-contained auto-refreshing HTML page (no
  Phoenix/LiveView dep in core).
- Both are dependency-free `render/1` functions exposed via a `Plug` (`BeamScope.Exporter.Router`,
  `GET /metrics` + `GET /`); `BeamScope.Exporters.Supervisor` optionally serves them on a standalone
  Bandit endpoint (`config :beam_scope, exporter: [port: N]`), or a host mounts the router itself.
  `plug`/`bandit` are optional deps; the router/endpoint only compile when present.
- **Exit criterion — MET:** live run serves `GET /metrics` (200, valid node-labelled Prometheus
  text) and `GET /` (200, HTML dashboard) on port 9568. 38 tests green (`mix precommit`), incl.
  render, scrape-from-ClusterState, and `Plug.Test` router cases.

### Inc 5 — Hardening  ✅
- **Property tests** (`stream_data`) for `ClusterState.merge/1` convergence: order-independent
  convergence to the max `{incarnation, version}` per node, idempotence under replay, and
  monotonic (never-regressing) clocks — the AP-safety guarantee of ADR-0005/0006.
- **Multi-node integration test** (`test/beam_scope/integration/cluster_sync_test.exs`, tagged
  `:distributed`, opt-in via `mix test --only distributed`): spins up a real peer with `:peer`,
  boots BeamScope over `:erpc`, and asserts the MVP acceptance criteria end-to-end.
- **Benchmarks** (`bench/`): `snapshot_size.exs` (per-node snapshot ≈ 0.65 KB compressed; state &
  scrape O(N); gossip deliveries O(N²) — the ADR-0005 scaling limit) and `pipeline.exs` (VM
  snapshot ≈ 0.4 µs, merge ≈ 2.6 µs, put_local ≈ 6.9 µs per op).
- **Docs**: `mix docs` builds cleanly (ExDoc); every module carries a `@moduledoc`.

## MVP acceptance test — "the architecture is sound"

On a **2-node local cluster** (`libcluster` LocalEpmd):

1. A VM / scheduler / process / ETS metric produced on **node A**
2. is visible via `BeamScope.vm(:"a@host")` **on node B** (proving synchronization),
3. and appears in **both** node B's **Prometheus scrape** and **dashboard** (proving exporters),
4. and, when node A leaves, node B's view of it degrades **gracefully** (`:live → :stale →
   :expired`), then **recovers** when A rejoins (proving AP + expiry, ADR-0005).

Passing this is the definition of done for v1 and the green light to add domains.

> **Status: MVP complete (Inc 0–5).** This acceptance test is automated by the `:distributed`
> integration test (`mix test --only distributed`) and was verified live on a 2-node cluster. The
> architecture is sound; adding domains/exporters/sync-strategies is now purely additive.

## Post-MVP (roadmap only — not scheduled here)

Each is *additive*, requiring **no core change** — the payoff of the architecture:

- **OpenTelemetry exporter** — "just another exporter" (ADR-0007).
- **Delta-CRDT synchronization strategy** and/or CRDT-backed `ClusterState` fields (membership,
  presence) behind the abstraction (ADR-0005/0006).
- **Sidecar / remote-observer topology** as an alternative strategy (ADR-0002).
- **Framework domain providers:** Phoenix, LiveView, Presence, Oban, Broadway, custom metrics
  (ADR-0008), each with optional deps and runtime presence detection.
