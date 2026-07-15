defmodule BeamScope.Synchronization do
  @moduledoc """
  Behaviour for **synchronizing** per-node runtime snapshots across the cluster.

  The synchronization algorithm is an implementation detail, not part of BeamScope's
  core architecture (see `docs/adr/0005`). This behaviour lets the strategy be
  replaced without touching aggregation, the runtime model, or exporters.

  The reference implementation is `BeamScope.Synchronization.SnapshotGossip`:
  versioned snapshot gossip over `Phoenix.PubSub`, with heartbeat-based stale-node
  expiration and **no leader election, consensus, or global locks** (an AP design —
  eventual consistency of *observations* is acceptable).

  Alternative strategies (delta-CRDT, Ra, `:erpc`, NATS, Kubernetes-specific) may be
  provided later without affecting the rest of the system.

  All strategies converge state into `BeamScope.ClusterState` via its merge/expire
  API (`docs/adr/0006`); CRDTs, where useful, live *behind* that abstraction.

  Reference implementation: `BeamScope.Synchronization.SnapshotGossip` (Inc 2).
  """

  @typedoc "A compact, versioned snapshot of one node's local runtime model."
  @type snapshot :: BeamScope.ClusterNode.t()

  @doc """
  Publish this node's latest local snapshot to peers.

  Driven by the strategy's own cadence (and callable by the aggregation layer for an
  explicit flush). Implementations must be non-blocking.
  """
  @callback publish(snapshot()) :: :ok

  @doc "Supervisable child spec for the strategy (subscription, timers, etc.)."
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()
end
