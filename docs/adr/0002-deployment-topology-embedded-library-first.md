# ADR-0002: Deployment topology — embedded library-first

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0001 (pipeline), ADR-0005 (synchronization), ADR-0003 (aggregation)

## Context

BeamScope must attach to a target Elixir cluster somehow. Two broad shapes exist: run *inside*
each target node as a library, or run *beside* the cluster as a separate observer node that reaches
in over distribution. The choice determines how telemetry is captured, where `ClusterState` lives,
what "a replica per node" means, and what BeamScope may assume about its host.

The vision states that *every node owns a replica of `ClusterState`* and that there is *no central
aggregator*. That strongly implies in-VM presence, but the trade-offs deserve to be explicit.

## Decision

**BeamScope ships primarily as an embedded library** — a hex dependency added to the target
application and started inside each node's BEAM.

- It **attaches telemetry handlers locally** and reads runtime introspection (`:erlang`,
  `:telemetry_poller`) in-process, where those operations are cheap and lock-free.
- It **does not own clustering.** Node discovery/connectivity is the host's responsibility
  (`libcluster`, `dns_cluster`, or plain distribution). BeamScope observes membership via
  `Node.list/0` and `:net_kernel.monitor_nodes/1`.
- It **references host infrastructure by name** through config — notably the host's
  `Phoenix.PubSub` server used by the default synchronization strategy (ADR-0005).
- **Every node runs the full pipeline and owns a full replica of `ClusterState`.** Any node can
  answer any query about any node from its local replica; there is no coordinator.

A **sidecar / remote-observer topology** (a separate BeamScope node observing over `:erpc`) is an
explicitly deferred alternative, kept on the roadmap. It is naturally expressible later as an
alternative synchronization strategy plus a remote-collection provider, *without* changing the core.

## Consequences

### Positive
- Cheapest possible telemetry capture: local handler attachment, no serialization of raw events.
- The "replica per node" invariant falls out for free; queries are always local and fast.
- Minimal new operational surface — no extra release to deploy, scale, or secure.
- Reuses infrastructure the host already runs (PubSub, clustering), matching the existing
  `crypto_pipe` / `file_swarm` deployment style.

### Negative / costs
- BeamScope shares the host's BEAM: a badly-behaved provider could compete for schedulers/memory
  with the application. This constrains ADR-0003 to strictly bounded, lock-free aggregation and
  makes provider isolation and back-pressure a first-class concern.
- Version coupling: BeamScope upgrades ride with host deploys.
- Observing the host from inside it means BeamScope cannot see a node that is truly down except as
  *absence* — which is exactly what the synchronization layer's expiry handles (ADR-0005).

## Alternatives considered

- **Sidecar-only (separate observer node).** Rejected as the primary shape: loses cheap local
  telemetry attachment, must pull data over the network (re-introducing a collector-like hop), and
  makes "replica per node" awkward. Valuable for hard isolation or polyglot clusters — retained as
  a future strategy, not the default.
- **Both, co-equal, from day one.** Rejected for MVP: doubles the design surface before the core
  loop is proven. We commit to *library-first* and design the synchronization boundary so a sidecar
  strategy can be added later at low cost.

## Failure modes & CAP

Because BeamScope lives in the observed node, its own availability tracks the node's. A partitioned
node continues to serve a locally-consistent view and simply sees peers as stale/expired
(ADR-0005). There is no shared component whose failure degrades the whole cluster's observability —
consistent with the no-central-aggregator, AP stance of ADR-0001.
