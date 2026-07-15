defmodule BeamScope.ClusterNode do
  @moduledoc """
  A node in the observed cluster and the entities observed on it (ADR-0004).

  `entities` is a generic map of `domain_key => [entity_struct]`, so a new domain
  provider (ADR-0008) contributes to the model with **zero core change** — no named
  field per domain. Inc 1 populates only `:vm`.

  The per-node logical clock is `{incarnation, version}` and is what synchronization
  merges on (ADR-0005/0006, last-observation-wins per node):

    * `incarnation` — the node's boot identity (a wall-clock timestamp set once when its
      `ClusterState` starts). It makes a **restart revive** correctly: after a crash the
      version counter resets, but the new, larger incarnation dominates the stale one.
    * `version` — a monotonic counter bumped on every local write within an incarnation.

  `liveness` reflects heartbeat freshness: `:live` → `:stale` → `:expired`.
  """

  @type liveness :: :live | :stale | :expired

  @type t :: %__MODULE__{
          node: node() | nil,
          liveness: liveness(),
          incarnation: non_neg_integer(),
          version: non_neg_integer(),
          observed_at: integer() | nil,
          entities: %{optional(atom()) => [struct()]}
        }

  defstruct node: nil,
            liveness: :live,
            incarnation: 0,
            version: 0,
            observed_at: nil,
            entities: %{}
end
