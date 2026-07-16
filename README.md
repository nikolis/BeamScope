# BeamScope

**A BEAM-native observability runtime for Elixir/OTP.**

BeamScope maintains a coherent, **distributed runtime model** of an Elixir cluster and exports
that model to existing observability ecosystems. It is deliberately *not* an OpenTelemetry
Collector, a Prometheus, a Grafana, or a monitoring database. Those tools are consumers.
BeamScope **owns the runtime model**.

> Status: **architecture phase.** This repository currently contains foundational Architecture
> Decision Records and an MVP roadmap. The `lib/` modules are documented stubs so the project
> compiles; functional behaviour is delivered incrementally per [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Core philosophy

**Synchronize observations, not replicate data.** High-frequency telemetry is aggregated locally
in ETS; only compact, versioned snapshots ever cross the network, and they are merged into a
per-node replica of the cluster model. There is no central aggregator, no consensus, and no
global lock — eventual consistency of *observations* is the correct and accepted trade-off.

## The pipeline

```
  Telemetry / Event Source
        │
        ▼
  Local Aggregation Engine        (ETS + :counters, periodic batching)
        │
        ▼
  Runtime Object Model            (rich concepts: VM, Scheduler, Process, ETS …)
        │
        ▼
  Synchronization                 (behaviour; default: snapshot gossip over Phoenix.PubSub)
        │
        ▼
  Cluster Runtime Model           (ClusterState — one replica per node)
        │
        ▼
  Exporters                       (Prometheus, LiveDashboard, OpenTelemetry — stateless adapters)
```

Per-node topology — every node is identical, no coordinator:

```
        target BEAM node (BeamScope embedded)
  ┌──────────────────────────────────────────────────────────────┐
  │  :telemetry / :telemetry_poller                                │
  │        │                                                       │
  │  DomainProviders → Local Aggregation (ETS) ─tick→ snapshot     │
  │                                                    │           │
  │                    BeamScope.Synchronization  (PubSub gossip)  │
  │                                                    │           │
  │  Exporters ◀── ClusterState (per-node replica) ◀───┘           │
  └──────────────────────────────────────────────────────────────┘
         ▲  Phoenix.PubSub (shared across cluster)  ▼
             — snapshots only, never raw telemetry —
```

## Architectural principles

- No central cluster aggregator; every node owns a replica of `ClusterState`.
- Eventual consistency is acceptable (an **AP** system).
- Message passing over global locks.
- The synchronization algorithm is a replaceable **behaviour**, not a core commitment.
- CRDTs are an *optimization* hidden behind the `ClusterState` abstraction, never the foundation.
- Exporters are stateless adapters.
- Runtime domains are **pluggable providers** — adding Phoenix/Oban/Broadway is "another plugin,"
  not a core change.

## Design decisions (ADRs)

| ADR | Decision |
| --- | --- |
| [0001](docs/adr/0001-core-pipeline-and-terminology.md) | Core pipeline & terminology (*synchronize observations, not replicate data*) |
| [0002](docs/adr/0002-deployment-topology-embedded-library-first.md) | Deployment topology: embedded library-first |
| [0003](docs/adr/0003-local-aggregation-engine.md) | Local aggregation engine (ETS + counters, batched snapshots) |
| [0004](docs/adr/0004-runtime-object-model.md) | Runtime object model (rich concepts, not raw counters) |
| [0005](docs/adr/0005-synchronization-behaviour-and-default-snapshot-gossip.md) | Synchronization behaviour + default snapshot gossip |
| [0006](docs/adr/0006-clusterstate-abstraction-and-crdt-as-optimization.md) | `ClusterState` abstraction + CRDTs as optimization |
| [0007](docs/adr/0007-exporter-behaviour.md) | Exporter behaviour (stateless adapters) |
| [0008](docs/adr/0008-domain-provider-plugin-architecture.md) | Domain-provider plugin architecture |
| [0009](docs/adr/0009-public-api-surface.md) | Public API surface |

Diagrams live under `docs/diagrams/`. Roadmap: [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Installation

BeamScope is an embedded library ([ADR-0002](docs/adr/0002-deployment-topology-embedded-library-first.md))
— it runs inside each node of your existing app. See
[`docs/INSTALL.md`](docs/INSTALL.md) for the full source-install guide (git/path deps, config,
exporters, umbrella projects, and verification).

```elixir
# mix.exs
defp deps do
  [{:beam_scope, github: "nikolisgal/beam_scope"}]
end
```

## Public API (MVP target)

```elixir
BeamScope.cluster()        # cluster-wide summary
BeamScope.nodes()          # known nodes + liveness
BeamScope.node(node)       # full model for one node
BeamScope.vm(node)         # memory, run queues, uptime
BeamScope.schedulers(node) # per-scheduler utilization
BeamScope.processes(node)  # process-population summary
BeamScope.ets(node)        # table count, memory, largest tables
```

## License

TBD.
