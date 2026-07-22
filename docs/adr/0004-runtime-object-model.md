# ADR-0004: Runtime object model

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0003 (aggregation), ADR-0006 (ClusterState), ADR-0009 (public API),
  ADR-0010 (bounded notable requests)

## Context

BeamScope's differentiator is that it exposes **a model of the running system**, not a bag of
counters. Prometheus already stores `beam_memory_total_bytes`; BeamScope's value is a `VM` concept
that knows its memory breakdown, run-queue lengths, and uptime, belongs to a `ClusterNode`, and can
be reasoned about programmatically. The shape of this model is what the public API (ADR-0009) and
every exporter (ADR-0007) are expressed in terms of, so it must be defined before them — but it
must also stay small enough to validate the architecture without boiling the ocean.

## Decision

**Model the runtime as a small set of explicit, versioned structs — rich runtime concepts, never
raw counters.**

MVP entities only:

| Struct | Represents | Illustrative fields |
| --- | --- | --- |
| `BeamScope.ClusterNode` | one node in the cluster | `node`, `liveness` (`:live`/`:stale`/`:expired`), `version`, `observed_at`, links to the structs below |
| `BeamScope.VM` | the emulator on a node | `memory` (total/processes/binary/ets/atom), `run_queue`, `uptime_ms`, `otp_release` |
| `BeamScope.Scheduler` | scheduler utilization | `count`, `online`, `utilization` (per-scheduler), `dirty_cpu`, `dirty_io` |
| `BeamScope.ProcessSummary` | process population | `count`, `limit`, `top_mailboxes` (bounded top-N `{pid, len}`), `top_memory` |
| `BeamScope.ETS` | ETS usage | `table_count`, `memory_bytes`, `largest` (bounded top-N tables) |

Cross-cutting rules:

- **The version clock lives on `ClusterNode`, not on each entity.** A node's entities are
  unversioned payload inside its `ClusterNode`, which carries the `{incarnation, version}` logical
  clock plus `observed_at`, stamped on every aggregation tick (ADR-0003). This is what
  synchronization merges on (ADR-0005/0006) — per-entity clocks would be redundant because
  snapshots are always full-node state and merges are per-node LWW. Note that each domain's
  aggregator ticks independently, so a node's `version` advances once per domain per interval and
  a gossiped snapshot may interleave domains from adjacent ticks — harmless for observations, but
  worth knowing when reasoning about a snapshot's exact composition.
- Entities are **plain structs** (data, not processes) so they are cheap to snapshot, serialize,
  merge, and diff.
- Collections are **bounded** (top-N) so a struct's size cannot grow with workload.
- The model is **the vocabulary of the whole system** — aggregation produces it, `ClusterState`
  stores/merges it, the public API returns it, exporters map from it.

The full 13-domain vision (Phoenix, LiveView, Presence, Oban, Broadway, custom, …) is **deferred to
domain-provider plugins** (ADR-0008). Each future domain adds its own struct(s); it does not change
the ones above.

## Consequences

### Positive
- A stable, self-describing surface that makes the public API and exporters straightforward to
  express and evolve.
- Versioned, bounded structs are ideal units for snapshot synchronization and last-observation-wins
  merges (ADR-0006).
- Small MVP set keeps the first milestone about *proving the pipeline*, not enumerating metrics.

### Negative / costs
- Rich structs risk over-modeling; we mitigate by shipping only the five above until real exporters
  and consumers pull more fields into existence.
- A typed model implies versioning discipline as fields are added; additive, backward-compatible
  changes are the rule, and snapshots must tolerate unknown fields from newer peers.

## Alternatives considered

- **Flat metric maps (`%{name => value}`).** Rejected: that *is* the thing BeamScope refuses to be;
  it pushes all meaning into naming conventions and defeats programmatic reasoning about the runtime.
- **Model live processes as entities (a struct per PID).** Rejected for MVP: unbounded cardinality
  and churn; `ProcessSummary` with bounded top-N captures the useful signal at bounded cost.
- **Derive the model lazily inside exporters.** Rejected: duplicates modeling logic per exporter and
  couples exporters to aggregation internals; the model must be the single shared representation.

## Failure modes & CAP

The model is passive data, so it has no runtime failure mode of its own. Its **versioning and
bounded-size rules are what make the AP synchronization safe**: peers can merge partial or
out-of-order snapshots deterministically (higher version per node wins, ADR-0006), and a
missing/stale node is representable directly via `ClusterNode.liveness` rather than as an error.
