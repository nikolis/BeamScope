defmodule BeamScope.Provider.ObanTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Oban, as: Provider
  alias BeamScope.Oban

  @start [:oban, :job, :start]
  @stop [:oban, :job, :stop]
  @exception [:oban, :job, :exception]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  defp start(acc, queue), do: Provider.aggregate(@start, %{}, %{queue: queue}, acc)
  defp stop(acc, queue), do: Provider.aggregate(@stop, %{}, %{queue: queue}, acc)
  defp exception(acc, queue), do: Provider.aggregate(@exception, %{}, %{queue: queue}, acc)

  test "executing is a live gauge: up on start, down on stop/exception", %{acc: acc} do
    start(acc, "imports")
    start(acc, "imports")
    start(acc, "ai_agents")

    assert [%Oban{executing: %{"imports" => 2, "ai_agents" => 1}}] = Provider.snapshot(acc)

    stop(acc, "imports")
    exception(acc, "ai_agents")

    assert [%Oban{executing: %{"imports" => 1, "ai_agents" => 0}}] = Provider.snapshot(acc)
  end

  test "completed/failed are windowed deltas, totals are monotonic", %{acc: acc} do
    start(acc, "imports")
    stop(acc, "imports")
    start(acc, "imports")
    exception(acc, "imports")

    assert [%Oban{} = o] = Provider.snapshot(acc)
    assert o.completed == %{"imports" => 1}
    assert o.failed == %{"imports" => 1}
    assert o.completed_total == 1
    assert o.failed_total == 1

    # a quiet window reports zero deltas but the monotonic totals hold
    assert [%Oban{completed: %{"imports" => 0}, failed: %{"imports" => 0}} = o2] =
             Provider.snapshot(acc)

    assert o2.completed_total == 1
    assert o2.failed_total == 1

    start(acc, "imports")
    stop(acc, "imports")

    assert [%Oban{completed: %{"imports" => 1}, completed_total: 2}] = Provider.snapshot(acc)
  end

  test "an unmatched stop clamps the executing gauge to zero, never negative", %{acc: acc} do
    stop(acc, "imports")

    assert [%Oban{executing: %{"imports" => 0}, completed: %{"imports" => 1}}] =
             Provider.snapshot(acc)
  end

  test "an atom queue name is normalized and a queueless event does not crash", %{acc: acc} do
    start(acc, :default)
    Provider.aggregate(@start, %{}, %{}, acc)

    assert [%Oban{executing: executing}] = Provider.snapshot(acc)
    assert executing["default"] == 1
    assert executing["unknown"] == 1
  end

  test "tolerates an empty accumulator", %{acc: acc} do
    assert [%Oban{} = o] = Provider.snapshot(acc)
    assert o.executing == %{}
    assert o.completed == %{}
    assert o.completed_total == 0
    assert o.window_ms == Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
  end

  test "provider has no poll/0 (purely event-driven)" do
    refute function_exported?(Provider, :poll, 0)
  end
end
