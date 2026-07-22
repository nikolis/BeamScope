# How BeamScope Works — A Component-by-Component Guide

This is a learning-oriented tour of the codebase: what each module does, why it exists,
and how they collaborate at runtime. The ADRs in `docs/adr/` record *why* decisions were
made; this document explains *what the code actually does*, in the order data flows
through it.

## The one-sentence version

Each node **measures itself**, folds those measurements into a compact per-node snapshot,
**gossips** that snapshot to every other node, and keeps a **full local copy** of everyone
else's snapshots — so any node can answer questions about the whole cluster instantly,
and exporters just read that local copy.

## The big picture

```
            ┌──────────────────── one BEAM node ────────────────────┐
            │                                                       │
  measure   │  Providers (VM, Scheduler, Processes, ETS)            │
            │      │  emit :telemetry events (driven by poller)     │
            │      ▼                                                │
  aggregate │  Aggregator (one per provider)                        │
            │      │  hot path: fold events into a private ETS acc  │
            │      │  every tick: snapshot() → structs              │
            │      ▼                                                │
  model     │  ClusterState  ←──────────────┐                       │
            │   (ETS: node → ClusterNode)   │ merge peer snapshots  │
            │      │                        │                       │
  sync      │      └─ publish own snapshot ─┤  SnapshotGossip       │
            │                               │  (Phoenix.PubSub)     │
  export    │  Prometheus / Dashboard / Router — read ClusterState  │
            └───────────────────────────────────────────────────────┘
                          ▲ PubSub topic "beam_scope:snapshots" ▼
                       every node runs this exact same picture
```

There is **no central server**. Every node runs the identical tree and holds a full
replica of the cluster model. The only thing that crosses the network is the small,
versioned `ClusterNode` snapshot — never raw telemetry.

---

## Component reference

### 1. `BeamScope.Application` (`lib/beam_scope/application.ex`)

The OTP entry point. It builds the supervision tree:

```
BeamScope.Supervisor (:one_for_one)
├── BeamScope.ClusterState            always — everything reads/writes it, so it starts first
├── Phoenix.PubSub                    only if start_pubsub: true (standalone/dev; embedded hosts bring their own)
├── BeamScope.Aggregation.Supervisor  only if aggregation: true (tests turn it off)
├── <sync strategy>                   only if both :sync and :pubsub are configured
└── BeamScope.Exporters.Supervisor    always, but inert unless an HTTP port is configured
```

The pattern to notice: **almost every child is conditional on config**. BeamScope is an
embedded library (ADR-0002) — it must be able to sit inside a host app without demanding
anything. A host that hasn't wired PubSub gets local-only observation; a host with no
port configured gets no HTTP server.

### 2. The measurement layer — `BeamScope.DomainProvider` and the four providers

`BeamScope.DomainProvider` (`lib/beam_scope/domain_provider.ex`) is a **behaviour** — an
interface that says "here is what it takes to observe one domain of the runtime":

| Callback | Role |
| --- | --- |
| `setup/0` (optional) | one-time global side effects (e.g. enable a VM flag) |
| `sources/0` | which telemetry event names this provider listens to |
| `poll/0` (optional) | read runtime stats and emit them as telemetry events |
| `aggregate/4` | fold **one** raw event into the provider's ETS accumulator (hot path) |
| `snapshot/1` | turn the accumulator into runtime-model structs (batch tick) |

The four MVP implementations live in `lib/beam_scope/provider/`:

* **`Provider.VM`** — memory breakdown (`:erlang.memory/0`), run-queue length, uptime,
  OTP release. Simplest provider; `aggregate` just stores the latest reading.
* **`Provider.Scheduler`** — scheduler utilization. The interesting one: utilization is a
  *delta between two cumulative `:scheduler_wall_time` samples*, so `aggregate` keeps the
  previous sample in the accumulator and computes `(active₂−active₁)/(total₂−total₁)` per
  scheduler. `setup/0` flips the global `:scheduler_wall_time` flag once.
* **`Provider.Processes`** — process count/limit plus top-N processes by mailbox length
  and by memory. `poll/0` scans `Process.list/0` each tick (O(process count), noted as a
  future optimization target).
* **`Provider.ETS`** — table count, total ETS memory (words × word size = bytes), top-N
  largest tables. Skips tables that vanish mid-scan.

All four follow the same shape: `poll/0` reads real BEAM stats and fires
`:telemetry.execute/3`; `aggregate/4` catches that event and writes the latest values into
ETS; `snapshot/1` reads ETS and returns a struct. Why the indirection through telemetry
instead of `poll` writing directly? Because future providers (Phoenix, Oban…) will consume
telemetry emitted *by other libraries* — the pipeline is built for that general case, and
the MVP providers exercise the same path.

**Adding a new domain requires zero core changes** (ADR-0008): implement the behaviour,
add `{MyProvider, :my_domain}` to `config :beam_scope, :providers`, done. The first
*framework* provider, `Provider.Phoenix` (opt-in), is exactly this: instead of a `poll/0`
it declares Phoenix's own `[:phoenix, :endpoint, :stop | :exception]` events as its
`sources/0` and folds them on the hot path — the first purely event-driven provider,
producing a windowed `BeamScope.Phoenix` (requests/errors/latency in the last tick, plus
per-node monotonic totals) queryable via `BeamScope.phoenix/1`.

### 3. `BeamScope.Aggregator` (`lib/beam_scope/aggregator.ex`)

The generic worker that runs *one provider*. This is where the "local aggregation engine"
(ADR-0003) lives, and it deliberately splits work into two phases:

* **Hot path** — at startup the aggregator attaches `handle_event/4` as a telemetry
  handler for the provider's `sources()`. Telemetry handlers run **in the process that
  emitted the event**, so folding an event into the ETS accumulator (a `:public` table
  with `write_concurrency`) never sends a message to the aggregator and never contends
  on a lock. High event volume can't flood a GenServer mailbox.
* **Batch tick** — a `:timer.send_interval` fires `:tick`; the aggregator calls
  `provider.snapshot(acc)` and writes the result into `ClusterState.put_local/1` under
  the provider's domain key.

Two robustness details worth understanding:

* If a provider's `aggregate/4` raises, `:telemetry` silently **detaches the handler** —
  in the emitting process, so the aggregator itself never crashes and no supervisor
  would notice. The aggregator therefore **re-attaches on every tick**
  (`reattach_if_detached/1`); the normal case is a cheap `{:error, :already_exists}`.
* It traps exits so `terminate/2` detaches the handler on shutdown; the handler id
  includes a `make_ref()` so a crashed instance can never block its replacement.

### 4. `BeamScope.Aggregation.Supervisor` (`lib/beam_scope/aggregation/supervisor.ex`)

Reads the provider list from config (default: the four MVP providers), starts **one
`Aggregator` per provider**, and starts **one shared `:telemetry_poller`** that calls
every provider's `poll/0` on the interval. Aggregators start *before* the poller so
handlers are attached before the first measurement fires.

### 5. The runtime object model — the structs

These are plain data, no processes (ADR-0004: "rich concepts, not raw counters"):

* **`BeamScope.ClusterNode`** (`lib/beam_scope/cluster_node.ex`) — *the* central data
  structure: one node's entire observed state. Its fields carry most of the distributed
  logic of the system:
  * `entities` — a generic map `domain => [struct]` (e.g. `%{vm: [%VM{}], ets: [%ETS{}]}`).
    Generic on purpose: new domains slot in without adding struct fields.
  * `{incarnation, version}` — the **logical clock** used for merging. `version` is a
    counter bumped on every local write; `incarnation` is a timestamp taken once at boot.
    Compared as a tuple, so after a node restarts (version resets to 0) its new, larger
    incarnation still beats any stale pre-restart snapshot a peer holds.
  * `observed_at` vs `received_at` — two timestamps with strictly separated roles.
    `observed_at` is the *sender's* wall clock: display only, never trusted for logic.
    `received_at` is stamped by the *receiving* node when it stores the entry, and it's
    what liveness expiry ages on — so clock skew between nodes can never falsely expire
    a live peer.
  * `liveness` — `:live` → `:stale` → `:expired` as heartbeats age out.
* **`BeamScope.VM`**, **`BeamScope.Scheduler`**, **`BeamScope.ProcessSummary`**,
  **`BeamScope.ETS`** — the per-domain entity structs that populate `entities`.

### 6. `BeamScope.ClusterState` (`lib/beam_scope/cluster_state.ex`)

The heart of the system: each node's **replica of the whole cluster model**. It's a
GenServer owning a named ETS table of `node => ClusterNode`, with an asymmetric design:

* **Reads bypass the process entirely.** `get/1` and `nodes/0` hit ETS directly —
  local, lock-free, no round-trip. This is why `BeamScope.vm(node)` is always fast and
  never a network call, even for remote nodes.
* **Writes are serialized through the GenServer.** The table is `:protected` (only the
  owner can write), so nothing can bypass version assignment or merge semantics.

Its write API is small and each call maps to one event in the system's life:

| Call | Called by | Meaning |
| --- | --- | --- |
| `put_local/1` | each Aggregator's tick | "here are my node's fresh entities" — bumps `version`, merges into the local entry's `entities` map |
| `merge/1` | SnapshotGossip, on receiving a peer broadcast | "a peer sent its snapshot" — kept only if its `{incarnation, version}` is newer than what's stored (last-observation-wins), then re-stamped with local `received_at` |
| `expire/2` | SnapshotGossip's periodic sweep | age remote entries: no snapshot for > TTL → `:stale`, > 2×TTL → `:expired` |
| `expire_node/1` | SnapshotGossip, on `:nodedown` | mark a departed peer `:expired` immediately rather than waiting for TTL |

Because merge is idempotent and commutative *per node* (each node only ever writes its own
snapshot; everyone else just picks the newest), no consensus or locking is needed —
duplicated, reordered, or lost gossip messages all converge to the same state.

### 7. Synchronization — `BeamScope.Synchronization` + `SnapshotGossip`

`BeamScope.Synchronization` (`lib/beam_scope/synchronization.ex`) is a two-callback
behaviour (`publish/1`, `child_spec/1`) so the gossip algorithm is **swappable** — a
CRDT- or NATS-based strategy could replace it without touching anything else.

The default, `BeamScope.Synchronization.SnapshotGossip`
(`lib/beam_scope/synchronization/snapshot_gossip.ex`), is a small GenServer that ties
four timers/subscriptions together:

1. **Publish tick** (every `sync_interval`, default 1s): read own `ClusterNode` from
   `ClusterState` and broadcast it on the PubSub topic `"beam_scope:snapshots"`. The
   default PubSub adapter relays broadcasts to same-named servers on all connected
   nodes — the host's existing clustering *is* the transport.
2. **Receive**: on `{:beam_scope_snapshot, snapshot}` from a peer, call
   `ClusterState.merge/1` (ignoring its own echoes).
3. **Sweep tick**: call `ClusterState.expire/2` so silent peers decay
   `:live → :stale → :expired`.
4. **`:nodedown`** (via `:net_kernel.monitor_nodes`): expire that peer immediately.
   `:nodeup` needs no handling — the rejoining node's own gossip (with a fresh, higher
   incarnation) revives it naturally.

### 8. Exporters — `Exporter`, `Prometheus`, `Dashboard`, `Router`, `Exporters.Supervisor`

Exporters are **stateless leaves** (ADR-0007): they read `ClusterState` and render it;
they hold no state and never write back.

* **`Exporter.Prometheus`** — renders the model as Prometheus text exposition **at scrape
  time**. `render/1` is a pure function over a list of `ClusterNode`s (independently
  testable); `scrape/0` is just `render(ClusterState.nodes())`. Rendering on demand,
  rather than pushing into a stateful metrics registry, means an expired node's series
  simply disappear instead of a last value lingering. Every series carries a `node`
  label, so scraping *any one node* yields the whole cluster's metrics.
* **`Exporter.Dashboard`** — same pattern, but renders a self-contained auto-refreshing
  HTML table for humans. No JavaScript, no Phoenix dependency.
* **`Exporter.Router`** — a tiny `Plug.Router`: `GET /metrics` → Prometheus,
  `GET /` → dashboard. The whole module is wrapped in
  `if Code.ensure_loaded?(Plug.Router)` — Plug is optional, and hosts without it can
  still call the pure render functions.
* **`Exporters.Supervisor`** — starts a standalone Bandit HTTP server for the Router,
  but *only* if `config :beam_scope, exporter: [port: …]` is set and Bandit is
  available. Hosts with their own web stack mount the Router themselves; then this
  supervisor supervises nothing.
* **`Exporter`** (the behaviour) — defines `export/1` as the seam for future *push*-based
  exporters (e.g. OpenTelemetry). Currently unimplemented, because both MVP exporters
  are pull-based.

### 9. `BeamScope` (`lib/beam_scope.ex`) — the public API

The deliberately small facade (ADR-0009): `cluster/0`, `nodes/0`, `node/1`, `vm/1`,
`schedulers/1`, `processes/1`, `ets/1`. Every function is a thin read of the local
`ClusterState` replica — which is why asking about a *remote* node is still a local ETS
lookup. `vm/1` etc. just pluck the (singleton) entity list out of the node's `entities`
map for that domain.

---

## How they collaborate: three walkthroughs

### A. One local tick (every second, on every node)

1. `:telemetry_poller` calls each provider's `poll/0`.
2. Each `poll/0` reads BEAM stats and fires `:telemetry.execute/3`.
3. Telemetry invokes the attached `Aggregator.handle_event/4` **in the polling process**,
   which calls `provider.aggregate/4` → latest values land in that provider's ETS
   accumulator.
4. Independently, each Aggregator's `:tick` fires: `provider.snapshot(acc)` builds the
   entity structs, and `ClusterState.put_local(%{domain => entities})` merges them into
   this node's `ClusterNode`, bumping `version`.

After one round of ticks, this node's own entry in `ClusterState` is fully populated.

### B. Cross-node convergence

1. `SnapshotGossip`'s publish tick broadcasts this node's `ClusterNode` over PubSub.
2. Every peer's `SnapshotGossip` receives it and calls `ClusterState.merge/1`.
3. Each peer keeps it iff `{incarnation, version}` is newer than what it has, stamping
   its own `received_at`.
4. Peers that fall silent decay to `:stale` then `:expired` via the sweep;
   `:nodedown` short-circuits straight to `:expired`; a restarted node's higher
   incarnation lets it reclaim its entry.

Result: within ~one gossip interval, every node's replica agrees (eventually consistent —
an AP system by design; no leader, no consensus, no locks).

### C. A read or a Prometheus scrape

1. `BeamScope.vm(:"other@host")` → `ClusterState.get/1` → direct ETS lookup on the
   **local** replica. No process call, no network.
2. Prometheus scrapes `GET /metrics` on any node → `Router` → `Prometheus.scrape()` →
   `render(ClusterState.nodes())` → text for the *entire cluster*, from that one node's
   local table.

## Mental model to keep

* **Two ETS layers, different jobs**: each provider's private *accumulator* (raw latest
  readings, written from hot telemetry paths) vs. the shared *ClusterState* table
  (finished `ClusterNode` models, one per node in the cluster).
* **Data always flows one way**: measure → aggregate → model → sync → export. Exporters
  never write; sync never measures; providers never touch ClusterState directly.
* **Everything cluster-wide is answered locally**, because every node carries a full
  replica kept fresh by gossip.
* **Config toggles the edges** (PubSub, sync, aggregation, HTTP), so the library adapts
  to embedded vs. standalone without code changes.
