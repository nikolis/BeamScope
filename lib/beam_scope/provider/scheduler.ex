defmodule BeamScope.Provider.Scheduler do
  @moduledoc """
  Domain provider for scheduler utilization (ADR-0004/0008).

  Utilization is a delta between two `:scheduler_wall_time` samples, so this provider is
  stateful across ticks: `poll/0` emits the raw cumulative sample, `aggregate/4` computes
  the per-scheduler and overall utilization against the previously stored sample, and
  `snapshot/1` assembles the `BeamScope.Scheduler` struct (with counts read fresh from the
  emulator).

  `setup/0` enables the global `:scheduler_wall_time` flag once. It carries a small,
  always-on runtime cost; drop this provider from `config :beam_scope, :providers` to
  avoid it.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.Scheduler

  @wall_time [:scheduler, :wall_time]

  @impl true
  def setup do
    :erlang.system_flag(:scheduler_wall_time, true)
    :ok
  end

  @impl true
  def sources, do: [@wall_time]

  @impl true
  def poll do
    :telemetry.execute(@wall_time, %{sample: :erlang.statistics(:scheduler_wall_time)}, %{})
    :ok
  end

  @impl true
  def aggregate(@wall_time, %{sample: sample}, _meta, acc) do
    prev = ets_get(acc, :prev_sample, nil)
    {overall, per} = utilization(prev, sample)

    :ets.insert(acc, {:computed, %{utilization: overall, per_scheduler: per}})
    :ets.insert(acc, {:prev_sample, sample})
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  @impl true
  def snapshot(acc) do
    computed = ets_get(acc, :computed, %{})

    scheduler = %Scheduler{
      count: :erlang.system_info(:schedulers),
      online: :erlang.system_info(:schedulers_online),
      dirty_cpu: :erlang.system_info(:dirty_cpu_schedulers),
      dirty_io: :erlang.system_info(:dirty_io_schedulers),
      utilization: Map.get(computed, :utilization),
      per_scheduler: Map.get(computed, :per_scheduler, [])
    }

    [scheduler]
  end

  # Compute utilization from two cumulative samples, matching schedulers by id (the
  # sample list is not guaranteed sorted). Returns {overall, per_scheduler}.
  defp utilization(prev, curr) when is_list(prev) and is_list(curr) do
    prev_by_id = Map.new(prev, fn {id, active, total} -> {id, {active, total}} end)

    per =
      curr
      |> Enum.map(fn {id, active2, total2} ->
        {active1, total1} = Map.get(prev_by_id, id, {active2, total2})
        %{id: id, utilization: ratio(active2 - active1, total2 - total1)}
      end)
      |> Enum.sort_by(& &1.id)

    {active_sum, total_sum} =
      Enum.reduce(curr, {0, 0}, fn {id, active2, total2}, {a_acc, t_acc} ->
        {active1, total1} = Map.get(prev_by_id, id, {active2, total2})
        {a_acc + (active2 - active1), t_acc + (total2 - total1)}
      end)

    {ratio(active_sum, total_sum), per}
  end

  defp utilization(_prev, _curr), do: {nil, []}

  defp ratio(_active, 0), do: 0.0
  defp ratio(active, total), do: active / total

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
