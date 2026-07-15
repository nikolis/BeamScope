# ADR-0001: Core pipeline & terminology

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** every other ADR derives from this one

## Context

BeamScope needs one canonical description of *what it does* and a consistent vocabulary, because
several superficially similar responsibilities (collecting telemetry, aggregating metrics,
propagating state, exporting to backends) are easy to conflate. Conflating them is how
observability tools accidentally become a metrics database or a central collector — precisely
what BeamScope must not be.

The system's single responsibility is to **maintain a coherent, distributed runtime model of a
BEAM cluster** and make it available to existing ecosystems. Everything else is a means to that
end.

A crucial early insight shapes the vocabulary. Databases *replicate data*: the values are
authoritative business facts and every replica must ultimately agree on them. BeamScope handles
something different — *observations of a running system*: scheduler utilization, memory, mailbox
sizes, ETS statistics. These are the latest reading from a node, not shared truth to be reconciled.
Calling this "replication" imports consistency expectations that do not apply and biases the design
toward consensus machinery we neither need nor want.

## Decision

1. **The canonical pipeline is:**

   ```
   Telemetry / Event Source
     → Local Aggregation Engine (ETS)
     → Runtime Object Model
     → Synchronization
     → Cluster Runtime Model (ClusterState)
     → Exporters
   ```

   Each stage is a distinct architectural concern with its own ADR. Data flows one way; exporters
   never write back into the model.

2. **Guiding principle — *synchronize observations, not replicate data.*** High-frequency
   telemetry is aggregated **locally**; only compact, versioned snapshots cross the network. Raw
   telemetry is never propagated between nodes.

3. **Terminology — "Synchronization," not "Replication," project-wide.** The layer that spreads
   snapshots across the cluster is *synchronization of observations*. This naming is load-bearing:
   it signals that eventual, per-node, last-observation-wins convergence is correct, and that
   consensus/leader-election are out of scope by default (see ADR-0005).

## Consequences

### Positive
- A shared mental model and vocabulary; each subsequent ADR slots cleanly into one pipeline stage.
- The "aggregate locally, ship snapshots" rule caps network cost independently of event frequency
  (ADR-0003), which is the property that makes cluster-wide observability affordable.
- Framing as *observations* keeps the door open to swap synchronization strategies (ADR-0005)
  without touching the rest of the pipeline.

### Negative / costs
- Renaming away from the more familiar "replication" costs some initial recognizability and
  requires discipline in docs and code review to avoid regressing to database vocabulary.
- One-way flow means exporters cannot be used as a write path; anything that must influence the
  model has to enter through telemetry/aggregation, by design.

## Alternatives considered

- **Keep "Replication" terminology.** Rejected: it invites consistency guarantees BeamScope does
  not provide and subtly pushes contributors toward consensus solutions.
- **Collapse stages (e.g. exporters read ETS directly).** Rejected: it couples exporters to
  aggregation internals and to a single node's view, defeating the cluster model and the pluggable
  synchronization boundary.

## Failure modes & CAP

BeamScope is an **AP** system by construction (elaborated in ADR-0005). Under partition, each side
keeps a locally-consistent, eventually-convergent view of the observations it can still receive;
stale nodes are expired rather than blocked on. The pipeline never introduces a synchronous
cross-node dependency on the hot path, so a slow or absent peer degrades *visibility*, never
*liveness*, of the observing node.
