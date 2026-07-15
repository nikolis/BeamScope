# ADR-0005: Synchronization behaviour + default snapshot gossip

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0001 (terminology), ADR-0004 (model), ADR-0006 (ClusterState), ADR-0002 (topology)

## Context

Once each node has a local runtime model (ADR-0003/0004), the cluster model is formed by spreading
those observations to every node's replica. *How* they spread — the synchronization algorithm — is
the single most consequential technical choice, and it is tempting to bake one in (Delta-CRDTs,
gossip, consensus). That temptation should be resisted.

BeamScope's real responsibility (ADR-0001) is maintaining a coherent runtime model, **not**
implementing a particular distributed-synchronization strategy. Different deployments have
legitimately different needs (a 3-node app vs. a 200-node fleet vs. a Kubernetes StatefulSet), and
the ecosystem already offers several primitives (`delta_crdt`, `Ra`, `:erpc`, NATS). Committing the
core to one of them would be an architectural mistake that is expensive to undo.

Crucially, what we synchronize are **observations** — "node A's latest VM reading is X @ version
N" — not shared business truth. That means the default can be extremely simple: newest observation
per node wins. No consensus is required for correctness.

## Decision

**Synchronization is a replaceable strategy defined by a behaviour, with a simple, robust default.**

### 1. `BeamScope.Synchronization` behaviour

```elixir
@callback publish(snapshot :: BeamScope.Synchronization.snapshot()) :: :ok
@callback child_spec(opts :: keyword()) :: Supervisor.child_spec()
```

The strategy is selected via `config :beam_scope, sync: <module>`. It is the *only* pipeline
component that knows how observations move between nodes; aggregation, the model, `ClusterState`,
and exporters are all agnostic to it. Strategies converge state exclusively through
`BeamScope.ClusterState`'s merge/expire API (ADR-0006).

### 2. Reference implementation — `BeamScope.Synchronization.SnapshotGossip`

Versioned snapshot gossip over the host's `Phoenix.PubSub`:

- On each aggregation tick, the node **broadcasts its compact, versioned snapshot** to a shared
  topic (e.g. `"beam_scope:snapshots"`).
- On receipt, a peer **merges by `{node, version}`**: a snapshot updates that node's entry in the
  local replica only if its `version` is newer (last-observation-wins *per node*). A node never
  overwrites another node's authority for its own observations.
- **Stale-node expiration by heartbeat:** each node's entry has a `node_ttl` (default 5 s). A
  periodic sweep marks entries `:stale` then `:expired` when snapshots stop arriving — the
  `Tracker` sweep pattern from `file_swarm`. `:net_kernel.monitor_nodes/1` provides prompt
  `:nodedown` expiry in addition to timeout.
- **No leader election, no consensus, no global locks, no distributed transactions.**

### 3. Explicit CAP stance

BeamScope is an **AP** system. Under partition, each side keeps serving and converging the
observations it can still see; unreachable nodes are expired, not waited on. We choose availability
and partition tolerance over strong consistency because *stale-but-available observability beats
consistent-but-unavailable observability* — a monitoring system that blocks during an incident is
worse than useless.

## Consequences

### Positive
- The hard decision (which algorithm) is deferred *by design*: teams pick what fits, and the
  project can add strategies without churn to the rest of the system.
- The default is trivial to understand, debug, and operate, and reuses PubSub — infrastructure
  Phoenix apps already run. Zero new distributed-systems dependency for the MVP.
- LWW-per-node needs no coordination and is exactly correct for "latest observation from a node."

### Negative / costs
- Gossip cost is `O(nodes²)` per tick in the naive full-mesh broadcast; fine for small/medium
  clusters, a scaling limit for large fleets. Mitigations (partial gossip, fan-out trees, digest
  diffing, a sidecar strategy) are future strategies, not core changes — the whole point of the
  behaviour.
- Eventual consistency means a viewer can briefly see a stale reading for a peer (bounded by tick +
  propagation). Acceptable for observability; called out so no one expects transactional freshness.
- Relies on the host running a suitable `Phoenix.PubSub`; a non-Phoenix host must configure one (or
  select a different strategy).

## Alternatives considered

- **Delta-CRDTs as the core replication engine (Horde-style).** Rejected as the foundation: heavier,
  new to the host stack, and overkill for measurements that are simply "latest per node." CRDTs are
  retained as an *optimization for specific mergeable aggregates behind `ClusterState`* (ADR-0006)
  and as a legitimate alternative `Synchronization` strategy — just not the default or the core.
- **Consensus (Ra/Raft) for a single agreed cluster view.** Rejected: introduces a CP dependency
  and unavailability under partition — the opposite of what observability needs — for a guarantee
  we do not require.
- **`:erpc`/RPC pull (each node scrapes peers on demand).** Rejected as default: turns read/scrape
  load into cross-node fan-out and re-creates a collector-ish coupling; kept viable as an alternative
  strategy (notably for a future sidecar topology, ADR-0002).
- **Hardcode gossip with no behaviour.** Rejected: it's the exact over-commitment this ADR exists to
  avoid.

## Failure modes & CAP

- **Node crash / partition:** peers stop receiving its snapshots; its entry ages to `:stale` then
  `:expired`. Observers stay available with a correctly-degraded view. On rejoin, the node's version
  counter has reset, so per-node ordering uses an **`{incarnation, version}`** logical clock: the
  `incarnation` is a boot timestamp that dominates the stale pre-crash state, so the first
  post-restart snapshot transparently revives the entry (verified by the Inc 2 two-node demo).
- **PubSub hiccup / dropped broadcast:** a lost snapshot is self-healing — the next tick supersedes
  it. No retransmission machinery is needed because snapshots are idempotent, versioned full-state
  summaries, not deltas that must all arrive.
- **Clock skew:** merge ordering uses a **monotonic per-node version**, not wall-clock, so skew
  cannot corrupt convergence; `observed_at` is display metadata only.
- **Strategy process crash:** supervised restart re-subscribes; a brief snapshot gap heals on the
  next tick.
