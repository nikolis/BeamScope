defmodule BeamScope.Synchronization.SnapshotGossip do
  @moduledoc """
  Default synchronization strategy: versioned snapshot gossip over `Phoenix.PubSub`
  (ADR-0005).

  Each node periodically broadcasts its compact local `BeamScope.ClusterNode` snapshot
  to a shared topic; peers merge it into their replica by `{incarnation, version}`
  (last-observation-wins per node). Absent nodes expire by heartbeat TTL, and
  `:net_kernel` `:nodedown` expires a peer promptly. **No leader election, no consensus,
  no locks** — an AP design.

  Requires the host's `Phoenix.PubSub` server name in config:

      config :beam_scope, pubsub: MyApp.PubSub, sync_interval: 1_000, node_ttl: 5_000

  The default PubSub adapter propagates broadcasts to same-named servers on every
  connected node, so no extra transport is needed — the host's clustering carries it.
  """

  @behaviour BeamScope.Synchronization

  use GenServer

  alias BeamScope.ClusterState

  @topic "beam_scope:snapshots"

  # --- Synchronization behaviour ---

  @impl BeamScope.Synchronization
  def publish(%BeamScope.ClusterNode{} = snapshot) do
    Phoenix.PubSub.broadcast(pubsub(), @topic, {:beam_scope_snapshot, snapshot})
  end

  def publish(nil), do: :ok

  @impl BeamScope.Synchronization
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Server ---

  @impl GenServer
  def init(_opts) do
    Phoenix.PubSub.subscribe(pubsub(), @topic)
    :net_kernel.monitor_nodes(true)

    ttl = ttl()
    {:ok, _} = :timer.send_interval(interval(), :publish)
    {:ok, _} = :timer.send_interval(sweep_interval(ttl), :sweep)

    {:ok, %{ttl: ttl}}
  end

  @impl GenServer
  def handle_info(:publish, state) do
    publish(ClusterState.get(Kernel.node()))
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    ClusterState.expire(System.system_time(:millisecond), state.ttl)
    {:noreply, state}
  end

  def handle_info({:beam_scope_snapshot, %BeamScope.ClusterNode{} = snapshot}, state) do
    # Ignore our own broadcast (we are subscribed to the same topic).
    unless snapshot.node == Kernel.node(), do: ClusterState.merge(snapshot)
    {:noreply, state}
  end

  def handle_info({:nodedown, the_node}, state) do
    ClusterState.expire_node(the_node)
    {:noreply, state}
  end

  # A rejoining node's own snapshots (with a newer incarnation) revive it via merge.
  def handle_info({:nodeup, _the_node}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # --- config ---

  defp pubsub, do: Application.fetch_env!(:beam_scope, :pubsub)
  defp interval, do: Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
  defp ttl, do: Application.get_env(:beam_scope, :node_ttl, :timer.seconds(5))
  defp sweep_interval(ttl), do: max(div(ttl, 5), 200)
end
