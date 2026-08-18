# BEAM VM Metrics — Feature Evaluation

This document evaluates the BEAM VM–level metrics BeamScope collects: **what** we
collect, **how** we collect it (the pipeline), and **which** of a requested checklist
of metrics are actually included today.

Scope note: this covers the VM/runtime domains. Application-domain metrics (Phoenix
requests/latency, Oban, LiveView, Ecto repo pools) are out of scope here except where
they overlap with VM stats. The sample `metrics` file at the repo root is a Prometheus
scrape from a *host* app (`mehungry`) via `telemetry_metrics`, **not** BeamScope's own
output — don't confuse the two.

---

## How we get them (the collection pipeline)

BeamScope uses a uniform, provider-based, two-phase pipeline. Nothing about VM stats is
special-cased; each runtime domain is just a `BeamScope.DomainProvider`.

```
:telemetry_poller ──period──▶ provider.poll/0 ──:telemetry.execute──▶ provider.aggregate/4
   (one shared poller)         (reads BEAM stats)                        (hot path: fold → ETS acc)
                                                                                │
                                                                                ▼
ClusterState ◀── snapshot entities ── provider.snapshot/1 ◀──:tick── BeamScope.Aggregator
   │                                    (batch tick, per interval)
   ▼
Exporter.Prometheus.render/1  (renders ClusterState to text at scrape time)
```

Concretely:

1. **Poll (source).** A single shared `:telemetry_poller`
   (`BeamScope.Aggregation.Supervisor`) invokes each provider's `poll/0` every
   `sync_interval` (default **1 s**). `poll/0` reads raw BEAM runtime stats — e.g.
   `:erlang.memory()`, `:erlang.statistics(:run_queue)`,
   `:erlang.statistics(:scheduler_wall_time)`, `:erlang.system_info(:process_count)` —
   and emits them via `:telemetry.execute/3`.

2. **Aggregate (hot path).** `BeamScope.Aggregator` attaches each provider's telemetry
   handler. On every event, `aggregate/4` folds the reading into a **lock-free public
   ETS accumulator** (`write_concurrency`), running in the emitting process — no message
   to the GenServer, no lock contention. Most VM gauges just overwrite "latest reading";
   the scheduler provider is stateful and computes a delta against the previous sample.

3. **Snapshot (batch tick).** On a periodic `:tick`, the Aggregator calls
   `snapshot/1`, which materializes a typed struct (`BeamScope.VM`,
   `BeamScope.Scheduler`, etc.) from the accumulator and writes it into
   `BeamScope.ClusterState` under its domain key. Some fields are read *fresh* here
   (e.g. scheduler counts via `:erlang.system_info/1`) rather than from the accumulator.

4. **Export (scrape time).** `BeamScope.Exporter.Prometheus.render/1` reads
   `ClusterState` on each scrape and renders the Prometheus text format. Every series is
   labelled by `node`, so any node exposes a cluster-wide view. Reading at scrape time
   (rather than a stateful reporter) means departed nodes' series simply stop appearing.

The enabled VM providers are the core defaults in `BeamScope.Aggregation.Supervisor`:

| Domain      | Provider                     | Struct                  | Key BEAM source(s)                              |
|-------------|------------------------------|-------------------------|-------------------------------------------------|
| `:vm`       | `BeamScope.Provider.VM`      | `BeamScope.VM`          | `:erlang.memory/0`, `:erlang.statistics(:run_queue)`, `:erlang.statistics(:wall_clock)` |
| `:scheduler`| `BeamScope.Provider.Scheduler`| `BeamScope.Scheduler`  | `:erlang.statistics(:scheduler_wall_time)`, `:erlang.system_info(:schedulers*)` |
| `:processes`| `BeamScope.Provider.Processes`| `BeamScope.ProcessSummary`| `:erlang.system_info(:process_count/:process_limit)`, `Process.list/0` + `Process.info/2` |
| `:ets`      | `BeamScope.Provider.ETS`     | `BeamScope.ETS`         | `:ets.all/0`, `:ets.info/2`                     |
| `:mailbox`  | `BeamScope.Provider.Mailbox` | `BeamScope.Mailbox`     | `Process.info(:message_queue_len)`              |

---

## What we actually collect today

### VM memory (`Provider.VM`)
`poll/0` emits the **full** `:erlang.memory()` map; `snapshot/1` keeps six kinds into
`BeamScope.VM.memory`:

- `total`, `processes`, `binary`, `ets`, `atom`, `code`

Exported as `beamscope_vm_memory_bytes{node,kind}`.
> Note: `:erlang.memory()` also returns `system`, `processes_used`, `atom_used`, etc.
> Those are available in the raw `[:vm, :memory]` event but not currently kept at snapshot.

### Run queue (`Provider.VM`)
`:erlang.statistics(:run_queue)` → `BeamScope.VM.run_queue` (aggregate total).
Exported as `beamscope_vm_run_queue{node}`.

### Runtime counters — GC / reductions / IO (`Provider.VM`)
Emitted as a single `[:vm, :runtime]` event and stored as **per-window deltas** (the
provider is stateful and diffs successive cumulative samples, like `Provider.Scheduler`):

- `gc_count`, `gc_words_reclaimed` — from `:erlang.statistics(:garbage_collection)`
- `gc_time_ms` — from `:erlang.statistics(:microstate_accounting)` (`:gc` counter → ms;
  requires the `:microstate_accounting` flag enabled in `setup/0`)
- `reductions` — from `:erlang.statistics(:reductions)` (total)
- `io` (`input`/`output`) — from `:erlang.statistics(:io)`

Exported as `beamscope_vm_gc_count`, `beamscope_vm_gc_words_reclaimed`,
`beamscope_vm_gc_time_ms`, `beamscope_vm_reductions`, and
`beamscope_vm_io_bytes{direction}` — all `node`-labelled. `nil` (series omitted) on the
first tick after start, since a delta needs a previous sample.

### Uptime / OTP release (`Provider.VM`)
`:erlang.statistics(:wall_clock)` → `uptime_ms`; `:erlang.system_info(:otp_release)`.
Exported as `beamscope_vm_uptime_ms{node}`.

### Scheduler utilization (`Provider.Scheduler`)
Delta of two `:scheduler_wall_time` samples → overall `utilization` (0.0–1.0) and
`per_scheduler` breakdown; plus counts `count`, `online`, `dirty_cpu`, `dirty_io`.
`nil` on the first tick. Requires the `:scheduler_wall_time` system flag (enabled once in
`setup/0`, small always-on cost). Exported as `beamscope_scheduler_utilization{node}` and
`beamscope_scheduler_online{node}`.

### Process population (`Provider.Processes`)
`process_count`, `process_limit`, plus a full `Process.list/0` scan for top-N processes by
mailbox length and by memory (`top_n`, default 5). Exported as
`beamscope_process_count{node}` and `beamscope_process_limit{node}`.

### ETS (`Provider.ETS`)
Table count, total memory (words → bytes via wordsize), and top-N largest tables.
Exported as `beamscope_ets_table_count{node}` and `beamscope_ets_memory_bytes{node}`.

### Mailbox (`Provider.Mailbox`)
Total queued, max queued, backlog count/threshold, distribution buckets. Exported as the
`beamscope_mailbox_*` families.

---

## Requested checklist — what is / isn't included

| Requested metric        | Included? | Where / notes |
|-------------------------|-----------|---------------|
| **Scheduler utilization** | ✅ Yes | `Provider.Scheduler`, overall + per-scheduler; `beamscope_scheduler_utilization` |
| **Run queue**             | ✅ Yes | `Provider.VM.run_queue` via `statistics(:run_queue)`; `beamscope_vm_run_queue` |
| **Process count**         | ✅ Yes | `Provider.Processes`; `beamscope_process_count` |
| **Process limit**         | ✅ Yes | `Provider.Processes`; `beamscope_process_limit` |
| **Total memory**          | ✅ Yes | `Provider.VM` memory kind `total`; `beamscope_vm_memory_bytes{kind="total"}` |
| **Process memory**        | ✅ Yes | memory kind `processes` |
| **Binary memory**         | ✅ Yes | memory kind `binary` |
| **ETS memory**            | ✅ Yes | memory kind `ets` **and** dedicated `beamscope_ets_memory_bytes` |
| **Atom memory**           | ✅ Yes | memory kind `atom` |
| **Code memory**           | ✅ Yes | memory kind `code`; `beamscope_vm_memory_bytes{kind="code"}` (now kept in snapshot) |
| **GC count / rate**       | ✅ Yes | `Provider.VM` via `statistics(:garbage_collection)`; per-window delta `beamscope_vm_gc_count` (+ `beamscope_vm_gc_words_reclaimed`) |
| **GC time**               | ✅ Yes | `Provider.VM` via `statistics(:microstate_accounting)` (msacc `:gc` counter → ms); per-window delta `beamscope_vm_gc_time_ms` |
| **BEAM process stats**    | ⚠️ Partial | Top-N by memory & mailbox (`Provider.Processes`) + full mailbox domain, but no per-process reductions/status/current-function. |
| **Reductions**            | ✅ Yes | `Provider.VM` via `statistics(:reductions)` (total); per-window delta `beamscope_vm_reductions` |
| **IO**                    | ✅ Yes | `Provider.VM` via `statistics(:io)`; per-window delta `beamscope_vm_io_bytes{direction="input"\|"output"}` |

### Summary (updated after implementation)
- **Fully included (14):** Scheduler utilization, Run queue, Process count, Process limit,
  Total / Process / Binary / ETS / Atom / **Code** memory, **GC count/rate**, **GC time**,
  **Reductions**, **IO**.
- **Partial (1):** BEAM process stats — top-N by memory/mailbox only; no per-process
  reductions/status/current-function (a deliberately bounded, dashboard-oriented surface).

### Implementation notes for the 4 (now 5, incl. code memory)
- **Code memory:** added `code` to the memory map in `Provider.VM.snapshot/1` and to
  `memory_kinds/1` in the exporter — the value already flowed through `poll/0`.
- **GC count/rate, GC time, Reductions, IO:** all emitted as a single new `[:vm, :runtime]`
  telemetry event from `Provider.VM.poll/0`. These are **cumulative-since-boot** counters,
  so `Provider.VM` became *stateful* (like `Provider.Scheduler`): `aggregate/4` diffs each
  sample against the previous one and stores the **per-window delta**; `snapshot/1` copies
  the delta onto `BeamScope.VM`. First tick emits no rate (no previous sample → `nil` →
  series omitted).
- **GC time** specifically requires microstate accounting: `Provider.VM.setup/0` enables
  the `:microstate_accounting` system flag once (small always-on cost), and `gc_time_ms`
  sums the `:gc` counter across all emulator threads and converts perf-counter units to ms.
  If the flag is off (provider removed from defaults), `gc_time_ms` is `nil` and simply not
  exported — the other counters are unaffected. Note: with 1 s windows, sub-millisecond GC
  truncates to `0`; it becomes non-zero under real GC pressure.

New Prometheus families:
`beamscope_vm_gc_count`, `beamscope_vm_gc_words_reclaimed`, `beamscope_vm_gc_time_ms`,
`beamscope_vm_reductions`, `beamscope_vm_io_bytes{direction}`, and
`beamscope_vm_memory_bytes{kind="code"}` — all `node`-labelled, all per-window deltas
(memory is instantaneous).

---

## Integration — how this data reaches Prometheus (incl. apps already on `TelemetryMetricsPrometheus.Core`)

There are two independent ways the new VM data lands in Prometheus. They are **not**
mutually exclusive, and an app already running `TelemetryMetricsPrometheus.Core` (TMP.Core)
can use either.

### The two moving parts

1. **BeamScope's own scrape path (default).** BeamScope renders the *cluster* runtime model
   to Prometheus text **at scrape time** (`BeamScope.Exporter.Prometheus`). It is served by
   `BeamScope.Exporter.Router` at `GET /metrics`, either mounted in the host's Plug/Phoenix
   stack or on BeamScope's optional standalone Bandit endpoint
   (`config :beam_scope, exporter: [port: 9568]`). Every series is `node`-labelled and
   reflects the whole cluster (each node holds a full replica via gossip), so one target
   exposes all nodes.

2. **The raw telemetry events.** The shared `:telemetry_poller` calls
   `Provider.VM.poll/0` every interval, which `:telemetry.execute/3`s three plain events:

   | Event            | Measurements (cumulative unless noted)                                   |
   |------------------|--------------------------------------------------------------------------|
   | `[:vm, :memory]` | full `:erlang.memory()` map — `total, processes, binary, ets, atom, code, system, …` (instantaneous) |
   | `[:vm, :run_queue]` | `total` (instantaneous)                                               |
   | `[:vm, :runtime]`| `gc_count, gc_words_reclaimed, gc_time_ms, reductions, io_input, io_output` (cumulative) |

   `BeamScope.Aggregator` is just one telemetry handler on these events. **Any other
   telemetry reporter can subscribe to the exact same events** — TMP.Core included.

### Option A — scrape BeamScope as a second target (zero code)

If the app already exposes `/metrics` via TMP.Core, just add BeamScope's endpoint as a
second Prometheus scrape target. Names never collide: BeamScope emits `beamscope_*`, the
app's TMP.Core emits its own metric names.

```yaml
# prometheus.yml
scrape_configs:
  - job_name: my_app          # existing TelemetryMetricsPrometheus.Core endpoint
    static_configs: [{ targets: ["app:9464"] }]
  - job_name: beamscope       # BeamScope.Exporter.Router (cluster-wide, node-labelled)
    static_configs: [{ targets: ["app:9568"] }]
```

You get BeamScope's semantics for free: **cluster-wide**, `node`-labelled, and the runtime
counters already delivered as **per-window deltas** (gauges).

### Option B — fold into the existing `TelemetryMetricsPrometheus.Core` endpoint (one endpoint)

If you want everything on the app's existing `/metrics` and don't want a second target,
point TMP.Core at the same events BeamScope's poller already emits — **no extra polling**,
one poll feeds both reporters. Add `Telemetry.Metrics` definitions to your existing
`TelemetryMetricsPrometheus.Core` child spec:

```elixir
import Telemetry.Metrics

metrics = [
  # ... your existing app metrics ...

  # VM memory (instantaneous gauges)
  last_value("vm.memory.total",     event_name: [:vm, :memory], measurement: :total, unit: :byte),
  last_value("vm.memory.processes", event_name: [:vm, :memory], measurement: :processes, unit: :byte),
  last_value("vm.memory.binary",    event_name: [:vm, :memory], measurement: :binary, unit: :byte),
  last_value("vm.memory.ets",       event_name: [:vm, :memory], measurement: :ets, unit: :byte),
  last_value("vm.memory.atom",      event_name: [:vm, :memory], measurement: :atom, unit: :byte),
  last_value("vm.memory.code",      event_name: [:vm, :memory], measurement: :code, unit: :byte),
  last_value("vm.run_queue.total",  event_name: [:vm, :run_queue], measurement: :total),

  # Runtime counters — the [:vm, :runtime] event carries CUMULATIVE totals, so expose them
  # as gauges (last_value) and let PromQL derive rates, OR use sum() if you prefer.
  last_value("vm.runtime.reductions",         event_name: [:vm, :runtime], measurement: :reductions),
  last_value("vm.runtime.gc_count",           event_name: [:vm, :runtime], measurement: :gc_count),
  last_value("vm.runtime.gc_words_reclaimed", event_name: [:vm, :runtime], measurement: :gc_words_reclaimed),
  last_value("vm.runtime.gc_time_ms",         event_name: [:vm, :runtime], measurement: :gc_time_ms),
  last_value("vm.runtime.io_input",           event_name: [:vm, :runtime], measurement: :io_input, unit: :byte),
  last_value("vm.runtime.io_output",          event_name: [:vm, :runtime], measurement: :io_output, unit: :byte)
]

# In your supervision tree (unchanged aside from the metrics list):
{TelemetryMetricsPrometheus.Core, metrics: metrics, name: :my_app_prometheus}
```

Then rate/increase in PromQL, e.g. `rate(vm_runtime_reductions[1m])`.

**Key semantic difference between the two options:**

| Aspect            | Option A — BeamScope exporter                | Option B — your TMP.Core reading the events |
|-------------------|----------------------------------------------|---------------------------------------------|
| Scope             | **Cluster-wide** (all nodes, `node` label)   | **Local node only** (this VM)               |
| Runtime counters  | **Per-window deltas** (pre-differenced gauges)| **Cumulative totals** (rate() in PromQL)    |
| Metric names      | `beamscope_vm_*`                             | Whatever you name them (`vm_*`)             |
| Extra work        | Add a scrape target                          | Add metric defs to an existing child        |
| Node liveness     | Departed nodes' series drop out automatically| N/A (single node)                           |

**Recommendation:** if you care about the *cluster* view and the `node`-labelled,
delta-ready series, use **Option A** — that's what BeamScope is for. If you only need the
*local* node's VM stats folded into an endpoint you already scrape, **Option B** reuses the
same telemetry events with no additional polling cost. You can also run both: TMP.Core for
local app+VM metrics, BeamScope's endpoint for the cluster-wide picture.
