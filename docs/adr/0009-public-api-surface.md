# ADR-0009: Public API surface

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0004 (model), ADR-0006 (ClusterState), ADR-0007 (exporters)

## Context

The public API is the contract users and exporters build on, so it should be defined deliberately
and kept intentionally small — a large surface locked in early is expensive to change later. It must
also embody the project's identity: expose **rich runtime concepts, not raw counters**. Defining it
now, against the MVP model (ADR-0004), also validates that the model is queryable and complete
enough before we build exporters on top of it.

## Decision

**A small, model-oriented `BeamScope` module is the public surface for the MVP:**

```elixir
BeamScope.cluster()        # cluster-wide summary across all known nodes
BeamScope.nodes()          # known nodes + liveness (:live | :stale | :expired)
BeamScope.node(node)       # the full runtime model for one node
BeamScope.vm(node)         # VM: memory breakdown, run queue, uptime
BeamScope.schedulers(node) # per-scheduler utilization
BeamScope.processes(node)  # process-population summary (counts, top mailboxes)
BeamScope.ets(node)        # ETS: table count, memory, largest tables
```

- **Every function returns runtime-model structs (ADR-0004), never bare numbers or metric maps.**
  The API speaks in `VM`, `Scheduler`, `ProcessSummary`, `ETS`, `ClusterNode`.
- **All queries are answered from the local `ClusterState` replica** (ADR-0002/0006) — reads are
  local, fast, and never trigger cross-node calls, even for `node/1` of a *remote* node (that data
  already arrived via synchronization).
- The surface is **additive-only** as new domains land (each future provider adds its own accessor,
  e.g. `BeamScope.phoenix(node)`), so the MVP contract stays stable.
- This module is the human/programmatic entry point; **exporters (ADR-0007) read `ClusterState`
  directly** rather than going through these convenience functions, to avoid a per-node round of
  struct-building on every scrape.

## Consequences

### Positive
- Small, memorable, concept-oriented — easy to learn and hard to misuse.
- Local-only reads make the API predictable and fast, and keep it honest about the AP model
  (liveness is a first-class part of `nodes/0` and `ClusterNode`).
- Additive growth means early adopters' code keeps working as domains are added.

### Negative / costs
- A curated surface means some advanced/ad-hoc queries aren't first-class; power users may need a
  lower-level `ClusterState` accessor later (a deliberate, additive extension).
- Returning rich structs (vs. plain maps) asks callers to pattern-match known shapes; justified by
  the clarity and evolvability it buys.

## Alternatives considered

- **Expose a generic query/metric-name API (`BeamScope.get("vm.memory.total", node)`).** Rejected:
  stringly-typed, reintroduces raw-counter thinking, and loses compile-time/structural clarity.
- **Return plain maps instead of structs.** Rejected: weaker contract, no type documentation, easier
  to drift; structs are the model's whole point (ADR-0004).
- **One catch-all query function doing everything** (`BeamScope.query(:vm, node)`). Rejected:
  discoverability and typing suffer versus a handful of named, concept-specific functions.

## Failure modes & CAP

Because reads are local, the API never blocks on a peer and never fails due to a partition — it
returns whatever the local replica currently knows, with `liveness` distinguishing fresh, stale, and
expired data. Querying a node that has expired returns its last-known model tagged accordingly (or a
clear "unknown node" result), rather than an error or a hang — the API surface *is* the AP contract
made visible to callers.
