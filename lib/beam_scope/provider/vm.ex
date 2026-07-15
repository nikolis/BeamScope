defmodule BeamScope.Provider.VM do
  @moduledoc """
  Domain provider for the VM (ADR-0004/0008).

  Framework-independent: it declares VM telemetry sources, folds the latest gauge
  readings into a lock-free ETS accumulator on the hot path (`aggregate/4`), and
  materializes a `BeamScope.VM` struct on the batch tick (`snapshot/1`).

  The measurements are emitted by a `:telemetry_poller` running `poll/0` on the
  aggregation interval, so the full source stage (`:telemetry` → `:telemetry_poller`)
  is genuinely exercised even though VM stats are low-frequency gauges.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.VM

  @memory [:vm, :memory]
  @run_queue [:vm, :run_queue]

  @impl true
  def sources, do: [@memory, @run_queue]

  # Hot path: store the latest reading, keyed, in the provider's ETS accumulator.
  @impl true
  def aggregate(@memory, measurements, _meta, acc) do
    :ets.insert(acc, {:memory, measurements})
    acc
  end

  def aggregate(@run_queue, measurements, _meta, acc) do
    :ets.insert(acc, {:run_queue, measurements})
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  # Batch tick: assemble the runtime-model entity from the latest readings.
  @impl true
  def snapshot(acc) do
    memory = ets_get(acc, :memory, %{})
    run_queue = ets_get(acc, :run_queue, %{})

    vm = %VM{
      memory: %{
        total: memory[:total],
        processes: memory[:processes],
        binary: memory[:binary],
        ets: memory[:ets],
        atom: memory[:atom]
      },
      run_queue: Map.get(run_queue, :total, 0),
      uptime_ms: uptime_ms(),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    }

    [vm]
  end

  @doc """
  Measurement function invoked periodically by `:telemetry_poller`.

  Reads BEAM runtime stats and emits them as telemetry, which `aggregate/4` folds.
  """
  @spec poll() :: :ok
  def poll do
    :telemetry.execute(@memory, Map.new(:erlang.memory()), %{})
    :telemetry.execute(@run_queue, %{total: :erlang.statistics(:run_queue)}, %{})
    :ok
  end

  defp uptime_ms do
    {total_wall_clock, _since_last} = :erlang.statistics(:wall_clock)
    total_wall_clock
  end

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
