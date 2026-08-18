defmodule BeamScope.Provider.VM do
  @moduledoc """
  Domain provider for the VM (ADR-0004/0008).

  Framework-independent: it declares VM telemetry sources, folds the latest gauge
  readings into a lock-free ETS accumulator on the hot path (`aggregate/4`), and
  materializes a `BeamScope.VM` struct on the batch tick (`snapshot/1`).

  The measurements are emitted by a `:telemetry_poller` running `poll/0` on the
  aggregation interval, so the full source stage (`:telemetry` → `:telemetry_poller`)
  is genuinely exercised even though VM stats are low-frequency gauges.

  Two families of reading are handled differently:

    * **gauges** (`memory`, `run_queue`) — instantaneous values, stored as "latest";
    * **runtime counters** (`gc`, `reductions`, `io`) — cumulative since VM start, so
      this provider is *stateful*: `aggregate/4` computes the per-tick delta against the
      previously stored sample (mirroring `BeamScope.Provider.Scheduler`). The delta over
      one poll interval is the per-window rate.

  `setup/0` enables `:microstate_accounting` once, which is what makes per-window **GC
  time** observable (`:erlang.statistics(:microstate_accounting)`). It carries a small,
  always-on runtime cost; to avoid it, remove this provider from the core defaults in
  `BeamScope.Aggregation.Supervisor` (GC time then reports `nil`, the other counters are
  unaffected).
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.VM

  @memory [:vm, :memory]
  @run_queue [:vm, :run_queue]
  @runtime [:vm, :runtime]

  @impl true
  def setup do
    :erlang.system_flag(:microstate_accounting, true)
    :ok
  end

  @impl true
  def sources, do: [@memory, @run_queue, @runtime]

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

  # Runtime counters are cumulative: keep the previous sample and store the per-tick delta.
  def aggregate(@runtime, sample, _meta, acc) do
    prev = ets_get(acc, :prev_runtime, nil)
    :ets.insert(acc, {:runtime_delta, runtime_delta(prev, sample)})
    :ets.insert(acc, {:prev_runtime, sample})
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  # Batch tick: assemble the runtime-model entity from the latest readings.
  @impl true
  def snapshot(acc) do
    memory = ets_get(acc, :memory, %{})
    run_queue = ets_get(acc, :run_queue, %{})
    runtime = ets_get(acc, :runtime_delta, %{})

    vm = %VM{
      memory: %{
        total: memory[:total],
        processes: memory[:processes],
        binary: memory[:binary],
        ets: memory[:ets],
        atom: memory[:atom],
        code: memory[:code]
      },
      run_queue: Map.get(run_queue, :total, 0),
      gc_count: runtime[:gc_count],
      gc_words_reclaimed: runtime[:gc_words_reclaimed],
      gc_time_ms: runtime[:gc_time_ms],
      reductions: runtime[:reductions],
      io: %{input: runtime[:io_input], output: runtime[:io_output]},
      uptime_ms: uptime_ms(),
      otp_release: List.to_string(:erlang.system_info(:otp_release))
    }

    [vm]
  end

  @doc """
  Measurement function invoked periodically by `:telemetry_poller`.

  Reads BEAM runtime stats and emits them as telemetry, which `aggregate/4` folds.
  """
  @impl true
  def poll do
    :telemetry.execute(@memory, Map.new(:erlang.memory()), %{})
    :telemetry.execute(@run_queue, %{total: :erlang.statistics(:run_queue)}, %{})
    :telemetry.execute(@runtime, runtime_sample(), %{})
    :ok
  end

  # Cumulative runtime counters read straight from the emulator. `aggregate/4` turns two
  # successive samples into a per-window delta.
  defp runtime_sample do
    {gc_count, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
    {total_reductions, _since_last} = :erlang.statistics(:reductions)
    {{:input, input}, {:output, output}} = :erlang.statistics(:io)

    %{
      gc_count: gc_count,
      gc_words_reclaimed: words_reclaimed,
      gc_time_ms: gc_time_ms(),
      reductions: total_reductions,
      io_input: input,
      io_output: output
    }
  end

  # Cumulative GC wall time (ms) summed across all emulator threads, via microstate
  # accounting. Returns nil when the flag is disabled (e.g. this provider's setup/0 was
  # skipped), so GC time simply won't be exported rather than reporting a bogus value.
  defp gc_time_ms do
    case :erlang.statistics(:microstate_accounting) do
      :undefined ->
        nil

      threads when is_list(threads) ->
        counter = Enum.sum(for %{counters: c} <- threads, do: Map.get(c, :gc, 0))
        # msacc counters are in os:perf_counter/0 units.
        :erlang.convert_time_unit(counter, :perf_counter, :millisecond)
    end
  end

  # First tick has no previous sample: emit no rates rather than a spurious full-total spike.
  defp runtime_delta(nil, _curr), do: %{}

  defp runtime_delta(prev, curr) do
    %{
      gc_count: curr.gc_count - prev.gc_count,
      gc_words_reclaimed: curr.gc_words_reclaimed - prev.gc_words_reclaimed,
      gc_time_ms: nonneg_delta(curr.gc_time_ms, prev.gc_time_ms),
      reductions: curr.reductions - prev.reductions,
      io_input: curr.io_input - prev.io_input,
      io_output: curr.io_output - prev.io_output
    }
  end

  defp nonneg_delta(curr, prev) when is_integer(curr) and is_integer(prev), do: curr - prev
  defp nonneg_delta(_curr, _prev), do: nil

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
