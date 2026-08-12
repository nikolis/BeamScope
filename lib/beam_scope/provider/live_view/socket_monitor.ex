defmodule BeamScope.Provider.LiveView.SocketMonitor do
  @moduledoc """
  Live count of connected LiveView sockets on this node, tracked by pid monitoring.

  LiveView emits telemetry on `mount` but has no "disconnected" event, so a live count cannot
  come from telemetry alone (ROADMAP: connection counts "need pid-`:DOWN` monitoring that
  Phoenix telemetry alone cannot provide"). This singleton GenServer `Process.monitor/1`s each
  connected LiveView process and drops it on `:DOWN`, keeping the current count in a public ETS
  cell so `snapshot/1` reads it lock-free and gets `0` if this monitor is not running.

  It is started idempotently from `BeamScope.Provider.LiveView.setup/0`. (A proper home in the
  supervision tree is a natural follow-up; a singleton started here is enough for a first pass
  and, unlinked, survives an aggregator re-attach.)
  """

  use GenServer

  @name __MODULE__
  @table :beam_scope_live_sockets

  @doc "Start the monitor if it is not already running (safe to call repeatedly)."
  @spec ensure_started() :: :ok
  def ensure_started do
    case GenServer.start(__MODULE__, :ok, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Begin tracking a connected LiveView process; drops automatically when it exits."
  @spec track(pid()) :: :ok
  def track(pid) when is_pid(pid), do: GenServer.cast(@name, {:track, pid})

  @doc "The current number of connected LiveView sockets (0 if the monitor is not running)."
  @spec count() :: non_neg_integer()
  def count do
    :ets.lookup_element(@table, :count, 2)
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@table, {:count, 0})

    # ref => pid, so the count is exactly map_size(refs) and a duplicate mount cannot double-count.
    {:ok, %{refs: %{}}}
  end

  @impl true
  def handle_cast({:track, pid}, state) do
    if Enum.any?(state.refs, fn {_ref, tracked} -> tracked == pid end) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      refs = Map.put(state.refs, ref, pid)
      publish(refs)
      {:noreply, %{state | refs: refs}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    refs = Map.delete(state.refs, ref)
    publish(refs)
    {:noreply, %{state | refs: refs}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp publish(refs), do: :ets.insert(@table, {:count, map_size(refs)})
end
