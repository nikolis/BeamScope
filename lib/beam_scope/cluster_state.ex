defmodule BeamScope.ClusterState do
  @moduledoc """
  The per-node replica of the cluster runtime model (ADR-0006).

  Owns a named, public ETS table of `node => BeamScope.ClusterNode`. **Reads go
  straight to ETS** (local and fast — no process round-trip); **writes are serialized
  through this GenServer** so the local node's monotonic `version` is assigned in one
  place.

  Merge semantics are **last-observation-wins per node**, ordered by the `{incarnation,
  version}` logical clock (`BeamScope.ClusterNode`) — idempotent and commutative per
  node, which is what makes AP synchronization (ADR-0005) safe. CRDTs, where ever needed,
  would live *behind* this module for specific fields; callers never see them.

  As of Inc 2, `merge/1`/`expire/2`/`expire_node/1` are driven cross-node by
  `BeamScope.Synchronization.SnapshotGossip`.
  """

  use GenServer

  alias BeamScope.ClusterNode

  @table :beam_scope_cluster_state

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Write this node's freshly-aggregated entities, assigning the next local version."
  @spec put_local(%{optional(atom()) => [struct()]}) :: ClusterNode.t()
  def put_local(entities) when is_map(entities) do
    GenServer.call(__MODULE__, {:put_local, entities})
  end

  @doc "Merge a peer's node snapshot (last-observation-wins by `{incarnation, version}`)."
  @spec merge(ClusterNode.t()) :: :merged | :ignored
  def merge(%ClusterNode{} = incoming) do
    GenServer.call(__MODULE__, {:merge, incoming})
  end

  @doc "Mark a specific remote node `:expired` immediately (e.g. on `:nodedown`)."
  @spec expire_node(node()) :: :ok
  def expire_node(the_node) do
    GenServer.call(__MODULE__, {:expire_node, the_node})
  end

  @doc "The `ClusterNode` for a node, or `nil` if unknown. Read directly from ETS."
  @spec get(node()) :: ClusterNode.t() | nil
  def get(the_node \\ Kernel.node()) do
    case :ets.lookup(@table, the_node) do
      [{^the_node, %ClusterNode{} = cn}] -> cn
      [] -> nil
    end
  end

  @doc "All known `ClusterNode`s."
  @spec nodes() :: [ClusterNode.t()]
  def nodes do
    :ets.tab2list(@table) |> Enum.map(fn {_node, cn} -> cn end)
  end

  @doc "Recompute liveness for remote nodes given `now` and a TTL (ms). Inc 2 caller."
  @spec expire(integer(), pos_integer()) :: :ok
  def expire(now, ttl) do
    GenServer.call(__MODULE__, {:expire, now, ttl})
  end

  @doc false
  # Test seam: clears the table through its owner (the table is `:protected`, so
  # non-owner processes cannot write to it directly).
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    # `:protected` keeps the representation private (ADR-0006): every write goes
    # through this owning process, so nothing can bypass version assignment or the
    # merge semantics; reads from any process stay direct and lock-free.
    table =
      :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    # The incarnation identifies this boot of the local node; it dominates any stale
    # pre-restart state a peer may still hold for us (ADR-0005 rejoin).
    {:ok, %{table: table, incarnation: System.system_time(:millisecond), version: 0}}
  end


  @impl true
  def handle_call({:put_local, entities}, _from, state) do
    version = state.version + 1
    local = Kernel.node()

    existing = get(local) || %ClusterNode{node: local}

    now = System.system_time(:millisecond)

    cn = %ClusterNode{
      node: local,
      liveness: :live,
      incarnation: state.incarnation,
      version: version,
      observed_at: now,
      received_at: now,
      entities: Map.merge(existing.entities, entities)
    }

    :ets.insert(@table, {local, cn})
    {:reply, cn, %{state | version: version}}
  end

  def handle_call({:merge, %ClusterNode{} = incoming}, _from, state) do
    result =
      if newer?(incoming, get(incoming.node)) do
        # Stamp the *local* receipt time: the TTL sweep must never compare our clock
        # against the sender's wall clock (`observed_at` is display metadata only —
        # ADR-0005 clock-skew guarantee).
        received = %{incoming | liveness: :live, received_at: System.system_time(:millisecond)}
        :ets.insert(@table, {incoming.node, received})
        :merged
      else
        :ignored
      end

    {:reply, result, state}
  end

  def handle_call({:expire_node, the_node}, _from, state) do
    if the_node != Kernel.node() do
      case get(the_node) do
        %ClusterNode{} = cn -> :ets.insert(@table, {the_node, %{cn | liveness: :expired}})
        nil -> :ok
      end
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:expire, now, ttl}, _from, state) do
    local = Kernel.node()

    for {n, %ClusterNode{} = cn} <- :ets.tab2list(@table), n != local do
      liveness = liveness_for(cn, now, ttl)
      if liveness != cn.liveness, do: :ets.insert(@table, {n, %{cn | liveness: liveness}})
    end

    {:reply, :ok, state}
  end

  # Order per-node observations by their {incarnation, version} logical clock.
  defp newer?(%ClusterNode{}, nil), do: true

  defp newer?(%ClusterNode{} = incoming, %ClusterNode{} = stored) do
    {incoming.incarnation, incoming.version} > {stored.incarnation, stored.version}
  end

  # Liveness ages on `received_at` — a timestamp *this* node stamped on merge — so
  # cross-node clock skew can never falsely expire a live peer or preserve a dead one.
  defp liveness_for(%ClusterNode{received_at: nil}, _now, _ttl), do: :expired

  defp liveness_for(%ClusterNode{received_at: received_at}, now, ttl) do
    cond do
      now - received_at > 2 * ttl -> :expired
      now - received_at > ttl -> :stale
      true -> :live
    end
  end
end
