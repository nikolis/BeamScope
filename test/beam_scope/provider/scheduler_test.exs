defmodule BeamScope.Provider.SchedulerTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Scheduler, as: Provider
  alias BeamScope.Scheduler

  @wall_time [:scheduler, :wall_time]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  test "utilization is nil until a second sample arrives", %{acc: acc} do
    Provider.aggregate(@wall_time, %{sample: [{1, 100, 1000}]}, %{}, acc)

    assert [%Scheduler{utilization: nil, per_scheduler: []}] = Provider.snapshot(acc)
  end

  test "computes per-scheduler and overall utilization from two samples", %{acc: acc} do
    # scheduler 1: active +500 over total +1000 => 0.5; scheduler 2: +0/+1000 => 0.0
    Provider.aggregate(@wall_time, %{sample: [{1, 100, 1000}, {2, 200, 1000}]}, %{}, acc)
    Provider.aggregate(@wall_time, %{sample: [{1, 600, 2000}, {2, 200, 2000}]}, %{}, acc)

    assert [%Scheduler{} = s] = Provider.snapshot(acc)
    # overall = (500 + 0) / (1000 + 1000)
    assert s.utilization == 0.25
    assert s.per_scheduler == [%{id: 1, utilization: 0.5}, %{id: 2, utilization: 0.0}]
    # counts come straight from the emulator
    assert s.count > 0 and s.online > 0
  end

  test "an :undefined sample (flag disabled) yields nil utilization", %{acc: acc} do
    Provider.aggregate(@wall_time, %{sample: :undefined}, %{}, acc)
    assert [%Scheduler{utilization: nil}] = Provider.snapshot(acc)
  end

  test "poll/0 emits the raw wall-time sample" do
    handler_id = "sched-poll-#{inspect(make_ref())}"
    parent = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = Provider.setup()

    :telemetry.attach(
      handler_id,
      @wall_time,
      fn _e, m, _meta, _cfg -> send(parent, {:sample, m.sample}) end,
      nil
    )

    Provider.poll()
    assert_receive {:sample, sample}
    assert is_list(sample)
  end
end
