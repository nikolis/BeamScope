# Installing BeamScope from Source

BeamScope is an **embedded library** (see [ADR-0002](adr/0002-deployment-topology-embedded-library-first.md)):
it runs *inside* each node of your existing Elixir/OTP application rather than as a standalone
service. This guide covers adding it to your project directly from source, since it is not (yet)
published to Hex.

## Prerequisites

- **Elixir** `~> 1.15` and a compatible Erlang/OTP.
- A Mix project to embed BeamScope into (the *host* application).
- If you want the default cross-node synchronization, your host must provide a
  [`Phoenix.PubSub`](https://hexdocs.pm/phoenix_pubsub) server and cluster the nodes
  (e.g. via `libcluster` or `Node.connect/1`). BeamScope references PubSub by name — it does
  not own clustering.

## 1. Add BeamScope as a dependency

Pick whichever source works for your workflow.

### Option A — Git dependency (recommended)

In your host app's `mix.exs`:

```elixir
defp deps do
  [
    {:beam_scope, github: "nikolisgal/beam_scope"}
    # pin a revision for reproducibility:
    # {:beam_scope, github: "nikolisgal/beam_scope", ref: "bdee165"}
    # or a branch/tag:
    # {:beam_scope, github: "nikolisgal/beam_scope", branch: "master"}
  ]
end
```

### Option B — Local path dependency

Useful when you have the repo checked out next to your app (e.g. for local development):

```elixir
defp deps do
  [
    {:beam_scope, path: "../beam_scope"}
  ]
end
```

Then fetch and compile:

```bash
mix deps.get
mix deps.compile beam_scope
```

### Umbrella projects

In an umbrella, dependencies live in each **child app's** `mix.exs`, not the umbrella root.
Add BeamScope to the single child app that should own observability — usually the one that
already owns `Phoenix.PubSub` (often the web app) or a dedicated `apps/my_app_telemetry`:

```elixir
# apps/my_app_web/mix.exs
defp deps do
  [
    {:beam_scope, github: "nikolisgal/beam_scope"}
    # A path dep to a sibling app inside the umbrella uses in_umbrella:
    # {:beam_scope, in_umbrella: true}   # only if beam_scope is itself an app under apps/
  ]
end
```

You do **not** need to add BeamScope to every child app. BeamScope is an OTP application with
its own supervision tree, so as long as *one* started app in the release depends on it (and thus
lists it under `extra_applications`/deps), it boots once for the whole node — every child app
running on that node shares the same per-node `ClusterState`.

Configuration is shared across the umbrella, so put the `config :beam_scope, ...` block in the
**umbrella root** `config/config.exs` (see step 3), not in a child app's config. Point `:pubsub`
at the PubSub server name your umbrella actually starts (e.g. `MyAppWeb.PubSub`).

## 2. Pull in the optional dependencies you need

BeamScope's **core** (telemetry aggregation, cluster model, sync) only needs `telemetry`,
`telemetry_poller`, and `phoenix_pubsub`, which come transitively.

The HTTP **exporters** (Prometheus `/metrics` + HTML dashboard `/`) are dependency-free
*render functions*, but serving them over BeamScope's own endpoint needs `plug` and `bandit`.
These are declared `optional: true` in BeamScope, so add them to **your** deps if you want the
standalone endpoint:

```elixir
{:plug, "~> 1.15"},
{:bandit, "~> 1.5"}
```

You can skip both if your host already runs a Plug/Phoenix stack and you mount the router
yourself (see step 4).

## 3. Configure BeamScope

BeamScope references host infrastructure **by name** via `config`. A typical embedded setup in
`config/config.exs` (or a runtime `config/runtime.exs`):

```elixir
config :beam_scope,
  # Point at your host's Phoenix.PubSub server (BeamScope does NOT start it in embedded mode).
  pubsub: MyApp.PubSub,

  # Default synchronization strategy: gossip compact snapshots over PubSub (ADR-0005).
  sync: BeamScope.Synchronization.SnapshotGossip,
  sync_interval: :timer.seconds(1),
  node_ttl: :timer.seconds(5),

  # Top-N bound for the Process/ETS providers (largest mailboxes / memory / tables).
  top_n: 5
```

### Notes

- **Synchronization is inert until both `:sync` and `:pubsub` are set.** An embedded host that
  hasn't wired PubSub yet stays safely idle (no gossip, single-node model only).
- **Domain providers** default to VM + Scheduler + Processes + ETS. Override to add/drop them —
  the shape is `[{provider_module, domain_atom}, ...]`:

  ```elixir
  config :beam_scope, providers: [{BeamScope.Provider.VM, :vm}]
  ```

  Dropping the Scheduler provider avoids enabling the global `:scheduler_wall_time` flag.
- **Standalone / dev without a host PubSub:** BeamScope can start its own PubSub for you:

  ```elixir
  config :beam_scope,
    pubsub: BeamScope.PubSub,
    start_pubsub: true,
    exporter: [port: 9568]
  ```

## 4. Expose the exporters (optional)

BeamScope's application starts automatically when your app boots (it's an OTP application with
its own supervision tree), so metrics collection needs no manual wiring. To *serve* them, choose
one:

### Option A — BeamScope's standalone endpoint

Set a port (and have `:bandit` available). `BeamScope.Exporters.Supervisor` boots a Bandit
endpoint automatically:

```elixir
config :beam_scope, exporter: [port: 9568]
```

- `GET /metrics` → Prometheus text exposition (node-labelled gauges)
- `GET /` → auto-refreshing HTML dashboard

### Option B — Mount the router in your existing stack

If your host already runs Phoenix/Plug, forward to `BeamScope.Exporter.Router` (requires `:plug`):

```elixir
# In your Phoenix Endpoint or a Plug pipeline:
forward "/beam_scope", to: BeamScope.Exporter.Router
```

### Option C — Just call the render functions

They need no process and no web server at all:

```elixir
BeamScope.Exporter.Prometheus.scrape()  # => Prometheus text
BeamScope.Exporter.Dashboard.page()     # => HTML string
```

## 5. Verify the install

Start your app and query the public API ([ADR-0009](adr/0009-public-api-surface.md)):

```elixir
BeamScope.cluster()          # cluster-wide summary
BeamScope.nodes()            # known nodes + liveness
BeamScope.node(node())       # full model for one node
BeamScope.vm(node())         # memory, run queues, uptime
BeamScope.schedulers(node()) # per-scheduler utilization
BeamScope.processes(node())  # process-population summary
BeamScope.ets(node())        # table count, memory, largest tables
```

A healthy single node returns a live `%BeamScope.VM{}` from `BeamScope.vm(node())` whose
`uptime_ms` and node `version` advance on each tick.

If you configured the exporter port, confirm the endpoints:

```bash
curl -s localhost:9568/metrics   # 200, Prometheus text
curl -s localhost:9568/          # 200, HTML dashboard
```

## 6. Multi-node check (optional)

To confirm synchronization end-to-end, cluster two nodes that share the same PubSub server name
and Erlang cookie. A metric produced on node A becomes visible via `BeamScope.vm(:"a@host")` on
node B, and node A leaving degrades B's view gracefully (`:live → :stale → :expired`), then
recovers when A rejoins. This is exactly the MVP acceptance test in
[`ROADMAP.md`](ROADMAP.md), automated by the `:distributed` integration test:

```bash
mix test --only distributed
```

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `BeamScope.vm/1` returns stale/empty data | Aggregation disabled (`config :beam_scope, aggregation: false`) or providers overridden to exclude VM. |
| Other nodes never appear | `:sync` or `:pubsub` not set, nodes not clustered, or mismatched PubSub server name / cookie. |
| No `/metrics` or `/` endpoint | `:bandit` not in your deps, or `exporter: [port: ...]` not configured. Use Option B/C instead. |
| `BeamScope.Exporter.Router` undefined | `:plug` not available — it only compiles when Plug is present. |
| A restarted node stays `:expired` | Expected briefly; the `{incarnation, version}` clock revives it on the next gossip tick. |

## References

- [`README.md`](../README.md) — architecture overview and pipeline.
- [`docs/ROADMAP.md`](ROADMAP.md) — increments and MVP acceptance test.
- ADRs [0002](adr/0002-deployment-topology-embedded-library-first.md) (embedded topology),
  [0005](adr/0005-synchronization-behaviour-and-default-snapshot-gossip.md) (synchronization),
  [0007](adr/0007-exporter-behaviour.md) (exporters),
  [0009](adr/0009-public-api-surface.md) (public API).
</content>
</invoke>
