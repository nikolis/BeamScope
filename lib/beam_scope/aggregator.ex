defmodule BeamScope.Aggregator do
  @moduledoc """
  Generic per-provider aggregation worker (ADR-0003).

  Owns a lock-free ETS accumulator, attaches the provider's telemetry handlers, and on
  a periodic tick materializes the provider's snapshot into `BeamScope.ClusterState`.

  Two-phase, matching the architecture:

    * **hot path** — telemetry handlers fold events into ETS via `provider.aggregate/4`
      (runs in the emitting process; no message to this GenServer, no lock contention);
    * **batch tick** — this worker calls `provider.snapshot/1` and writes the resulting
      entities to the local `ClusterState` entry under `domain`.

  Start one per provider:

      {BeamScope.Aggregator, provider: BeamScope.Provider.VM, domain: :vm, interval: 1000}
  """

  use GenServer

  alias BeamScope.ClusterState

  def start_link(opts) do
    provider = Keyword.fetch!(opts, :provider)
    GenServer.start_link(__MODULE__, opts, name: name(provider))
  end

  def child_spec(opts) do
    provider = Keyword.fetch!(opts, :provider)
    %{id: {__MODULE__, provider}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def name(provider), do: Module.concat(__MODULE__, provider)

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervised shutdown and detaches the telemetry
    # handler — otherwise the handler leaks and would fire against a deleted acc table.
    Process.flag(:trap_exit, true)

    provider = Keyword.fetch!(opts, :provider)
    domain = Keyword.fetch!(opts, :domain)
    interval = Keyword.fetch!(opts, :interval)

    if Code.ensure_loaded?(provider) and function_exported?(provider, :setup, 0),
      do: provider.setup()

    acc =
      :ets.new(:beam_scope_acc, [
        :public,
        :set,
        {:write_concurrency, true},
        read_concurrency: true
      ])

    # Unique per instance: a crashed instance that skipped terminate/2 cannot block a
    # restarted instance from attaching (its own stale handler self-heals on next fire).
    handler_id = {__MODULE__, provider, make_ref()}

    state = %{provider: provider, domain: domain, acc: acc, handler_id: handler_id}
    :ok = attach_handler(state)

    {:ok, timer} = :timer.send_interval(interval, :tick)

    {:ok, Map.put(state, :timer, timer)}
  end

  @doc false
  # Runs in the process that emitted the telemetry event.
  def handle_event(event, measurements, metadata, %{provider: provider, acc: acc}) do
    provider.aggregate(event, measurements, metadata, acc)
    :ok
  end

  @impl true
  def handle_info(:tick, state) do
    # Self-heal (ADR-0008 fault isolation): if `aggregate/4` raised, :telemetry
    # detached the handler in the *emitting* process — this GenServer never crashed,
    # so no supervisor restart would recover the domain. Re-arm it every tick.
    reattach_if_detached(state)

    entities = state.provider.snapshot(state.acc)
    ClusterState.put_local(%{state.domain => entities})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp attach_handler(state) do
    :telemetry.attach_many(
      state.handler_id,
      state.provider.sources(),
      &__MODULE__.handle_event/4,
      %{provider: state.provider, acc: state.acc}
    )
  end

  defp reattach_if_detached(state) do
    case attach_handler(state) do
      # The handler was gone (a raising aggregate/4 got it detached) — re-armed.
      :ok -> :ok
      # Normal case: still attached.
      {:error, :already_exists} -> :ok
    end
  end
end
