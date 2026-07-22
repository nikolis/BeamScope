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

Each item below is *additive*, requiring **no core change** — that is the payoff of the
architecture, and the reason this section is a **menu, not a timeline**. Items are grouped by the
pipeline stage they extend and are deliberately **unordered**: a team pulls in whichever fit its
deployment (a 3-node app and a 200-node fleet want different things), and each lands behind an
existing behaviour or the config-driven plugin list. Where an item is large enough to deserve its
own ADR, that is noted inline rather than pre-authored here.

### Exporters (ADR-0007)

Exporters are stateless leaves that read `ClusterState` and project it downstream; adding one is
"implement `export/1` (or a `render/1`/`Plug` seam), toggle it on."

- **OpenTelemetry exporter** — the canonical "just another exporter" (ADR-0007): maps the runtime
  object model to OTLP and ships it. This is a **push** exporter, so it uses the streaming wiring
  around `export/1` rather than the Prometheus/dashboard **pull** (`render/1`) seam — the
  per-exporter difference ADR-0007 already anticipates. No core change; the strongest validation
  that the exporter boundary is right.
- **LiveDashboard / LiveView page** — a Phoenix LiveView exporter as a richer alternative to the
  dependency-free HTML dashboard, carrying Phoenix/LiveView as **optional** deps so plain library
  users pull in nothing. ADR-0007 explicitly keeps this as a "natural future exporter — just
  another adapter."

### Synchronization strategies (ADR-0005/0006)

The synchronization algorithm is a replaceable strategy behind `BeamScope.Synchronization`,
selected via `config :beam_scope, sync:`; every strategy converges purely through
`ClusterState.merge/expire`. Two distinct axes live here — swapping the *strategy*, and changing
how a *field* converges inside `ClusterState`:

- **Delta-CRDT synchronization strategy** — an alternative `Synchronization` implementation over
  `delta_crdt`, replacing snapshot gossip wholesale for deployments that prefer it. Retained by
  ADR-0005 as a legitimate strategy — just not the default or the core.
- **CRDT-backed `ClusterState` fields** — *distinct from the above*: backing a **specific** aggregate
  (OR-set cluster membership, presence-like sets, a genuinely additive cluster-wide counter, an LWW
  map) with a delta-CRDT *inside* `ClusterState`, while the default per-node LWW covers everything
  else. Callers still go through the `ClusterState` API and never see a CRDT (ADR-0006). Opt-in and
  localized to the handful of fields that benefit.
- **Gossip scaling mitigations** — partial gossip, fan-out trees, or digest diffing to relax the
  naive `O(nodes²)`-per-tick full-mesh broadcast (ADR-0005) for large fleets. These are future
  *strategies* (or refinements of the default), not core changes — the whole point of the behaviour.
- **Other strategies** — `:erpc`/RPC pull, `Ra`, or NATS, each viable behind the same behaviour as
  ADR-0005's alternatives note (RPC pull is also the natural fit for the sidecar topology below).

### Domain providers (ADR-0008)

Each runtime domain is a `BeamScope.DomainProvider` plugin on the config-driven `:providers` list;
adding one is three callbacks plus a registration, with **zero core change**. Framework-specific
providers carry their deps as **optional** and activate only when the target library and its
telemetry are present.

- **Mailbox** domain — the remaining framework-independent domain from the 13-domain vision
  (ADR-0004/0008), distinct from `ProcessSummary`, built solely on runtime introspection.
- **Framework providers** — Phoenix, LiveView, Presence, Oban, Broadway, and custom metrics. Each
  contributes its own struct(s) to the model, adds its own additive `BeamScope.<domain>(node)`
  accessor (ADR-0009), and is fault-isolated to its own domain's snapshots.

### Deployment topology (ADR-0002)

- **Sidecar / remote-observer topology** — a separate BeamScope node observing a target cluster over
  `:erpc`, rather than the default embedded library. Expressible as an alternative synchronization
  strategy plus a remote-collection provider *without changing the core* — valuable for hard
  isolation or polyglot clusters. Deferred by ADR-0002 as a future shape, not the default.

### Scaling & hardening (ADR-0002/0003)

- **Provider back-pressure & isolation** — bounding a badly-behaved provider's competition for the
  host's schedulers/memory, the first-class concern ADR-0002/0003 flag for an embedded observer.
  Builds on the existing bounded, lock-free aggregation (top-N, fixed cardinality) and per-domain
  supervision rather than replacing them.

### Public API (ADR-0009)

- **Lower-level `ClusterState` accessor** — a deliberate, additive escape hatch for power users'
  ad-hoc queries beyond the curated, concept-oriented `BeamScope` surface (ADR-0009), without
  turning the API stringly-typed.
