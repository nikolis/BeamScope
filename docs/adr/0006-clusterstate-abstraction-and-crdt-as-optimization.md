# ADR-0006: `ClusterState` abstraction + CRDTs as optimization

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0004 (model), ADR-0005 (synchronization), ADR-0009 (public API)

## Context

Every node holds a replica of the cluster runtime model (ADR-0002). Two responsibilities meet here:
*storing and querying* the merged model (for the public API and exporters), and *merging* incoming
observations (for synchronization). If callers see the storage representation directly, we can never
change how state converges — and we specifically want the freedom to introduce CRDTs for a *few*
aggregates later without rewriting anything. So the merged model needs a stable abstraction with a
hidden representation.

## Decision

**`BeamScope.ClusterState` is the queryable, merged, per-node replica, behind a stable API; its
internal representation is private.**

- **Public-ish surface (used by synchronization strategies and the query layer):**

  ```elixir
  ClusterState.get(node)            # a node's current ClusterNode (direct ETS read)
  ClusterState.nodes()              # all nodes + liveness
  ClusterState.put_local(entities)  # write local entities; version assigned internally
  ClusterState.merge(snapshot)      # apply a peer snapshot (LWW-per-node by {incarnation, version})
  ClusterState.expire(now, ttl)     # sweep stale/expired nodes (ADR-0005 TTL)
  ClusterState.expire_node(node)    # expire one node promptly (e.g. on :nodedown)
  ```

  Version assignment is deliberately *not* a caller concern (`put_local/1` rather than a
  `put(node, entities, version)`): the monotonic local clock stays entirely inside the
  abstraction, which is more encapsulated than exposing it.

- **Default representation:** a versioned per-node map — `%{node => %{entities, version, observed_at,
  liveness}}` — held in an ETS table owned by a `ClusterState` process, with **last-observation-wins
  per node** merge keyed on monotonic `version`. This is enough for the MVP and for the vast
  majority of observability state, which is "latest reading from a node."

- **CRDTs are an optimization, hidden behind this API — never the foundation.** Where a *specific*
  aggregate genuinely benefits from coordination-free convergence across nodes — e.g. cluster
  membership (OR-set), presence-like sets, or a genuinely additive cluster-wide counter (G/PN-counter),
  or a last-write-wins map — a delta-CRDT may back *that field* internally. Callers still go through
  `ClusterState`; they never see a CRDT. Most runtime measurements (scheduler utilization, memory,
  mailbox sizes, ETS stats) are per-node latest observations and need **no** CRDT at all.

- **`ClusterState` is representation-agnostic to the synchronization strategy (ADR-0005):** any
  strategy converges by calling `merge/expire`. Swapping gossip for a CRDT strategy, or adding a
  CRDT-backed field, does not change the query surface.

## Consequences

### Positive
- The storage/merge representation can evolve (per-node LWW today, CRDT-backed fields tomorrow)
  without touching the public API, exporters, or synchronization callers.
- CRDT complexity is opt-in and *localized* to the handful of aggregates that need it, keeping the
  common path simple and dependency-free.
- A single, testable merge contract (`merge/expire`) is the seam where all convergence behavior —
  and thus most correctness risk — is concentrated.

### Negative / costs
- An abstraction layer adds indirection; we keep it thin (a small module + one owning process/ETS
  table) so it doesn't become ceremony.
- Mixing LWW-per-node fields with occasional CRDT-backed fields inside one abstraction needs clear
  internal rules so contributors know which fields have which semantics; documented per field.

## Alternatives considered

- **Expose the ETS table / raw map directly.** Rejected: freezes the representation forever and
  leaks merge semantics to every caller — the exact coupling this ADR prevents.
- **Make everything a CRDT.** Rejected: pays convergence-machinery cost (metadata, memory, tombstones)
  for data that is just "latest per node," and imports a heavy dependency the host stack doesn't use.
- **Per-domain bespoke stores.** Rejected: fragments query and merge logic; a single `ClusterState`
  with typed entity sets keeps one merge contract and one query surface.

## Failure modes & CAP

`ClusterState` is the concrete expression of the AP stance (ADR-0005). `merge/2` must be
**idempotent and commutative per node** (higher version wins) so out-of-order or duplicate snapshots
converge deterministically — the property CRDTs give globally, achieved here cheaply per node.
`expire/1` guarantees a partitioned/dead node cannot linger as apparently-live state. If the
`ClusterState` process crashes, its supervised restart rebuilds from the next round of incoming
snapshots (a brief, self-healing gap), since snapshots are full-state and idempotent.
