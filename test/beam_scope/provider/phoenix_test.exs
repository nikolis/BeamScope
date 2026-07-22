defmodule BeamScope.Provider.PhoenixTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Phoenix, as: Provider
  alias BeamScope.Phoenix

  @stop [:phoenix, :endpoint, :stop]
  @exception [:phoenix, :endpoint, :exception]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  defp stop(acc, status, ms) do
    duration = System.convert_time_unit(ms, :millisecond, :native)
    Provider.aggregate(@stop, %{duration: duration}, %{conn: %{status: status}}, acc)
  end

  test "aggregate/4 folds requests and snapshot/1 builds a windowed Phoenix model", %{acc: acc} do
    stop(acc, 200, 5)
    stop(acc, 200, 30)
    stop(acc, 404, 12)
    stop(acc, 500, 250)

    Provider.aggregate(
      @exception,
      %{duration: System.convert_time_unit(9, :millisecond, :native)},
      %{},
      acc
    )

    assert [%Phoenix{} = p] = Provider.snapshot(acc)

    # 4 :stop + 1 :exception
    assert p.requests == 5
    # one 500 + one exception
    assert p.errors == 2
    assert p.error_rate == 2 / 5
    assert is_float(p.avg_latency_ms)
    assert p.status_classes == %{"2xx" => 2, "3xx" => 0, "4xx" => 1, "5xx" => 2}

    assert p.latency_distribution == %{
             "0-10" => 2,
             "10-50" => 2,
             "50-200" => 0,
             "200-1000" => 1,
             "1000+" => 0
           }

    # per-node monotonic totals reflect all activity
    assert p.requests_total == 5
    assert p.errors_total == 2
    assert p.window_ms == Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
  end

  test "snapshot/1 windows on the delta since the previous tick", %{acc: acc} do
    stop(acc, 200, 5)
    stop(acc, 200, 5)
    assert [%Phoenix{requests: 2, requests_total: 2}] = Provider.snapshot(acc)

    # Nothing new before the next tick → an empty window, but totals hold.
    assert [%Phoenix{requests: 0, errors: 0, requests_total: 2}] = Provider.snapshot(acc)

    stop(acc, 500, 5)

    assert [%Phoenix{requests: 1, errors: 1, requests_total: 3, errors_total: 1} = p] =
             Provider.snapshot(acc)

    assert p.status_classes == %{"2xx" => 0, "3xx" => 0, "4xx" => 0, "5xx" => 1}
  end

  test "snapshot/1 tolerates an empty accumulator", %{acc: acc} do
    assert [%Phoenix{} = p] = Provider.snapshot(acc)
    assert p.requests == 0
    assert p.errors == 0
    assert p.error_rate == 0.0
    assert p.avg_latency_ms == nil
    assert p.requests_total == 0
    assert map_size(p.latency_distribution) == 5
    assert map_size(p.status_classes) == 4
  end

  test "aggregate/4 ignores unknown events", %{acc: acc} do
    assert Provider.aggregate([:phoenix, :other], %{x: 1}, %{}, acc) == acc
  end

  test "aggregate/4 tolerates a :stop with no conn/status in metadata", %{acc: acc} do
    Provider.aggregate(@stop, %{duration: 0}, %{}, acc)

    assert [%Phoenix{requests: 1, errors: 0} = p] = Provider.snapshot(acc)
    # unknown status is not attributed to any class
    assert p.status_classes == %{"2xx" => 0, "3xx" => 0, "4xx" => 0, "5xx" => 0}
    assert p.latency_distribution["0-10"] == 1
  end

  test "provider has no poll/0 (purely event-driven)" do
    refute function_exported?(Provider, :poll, 0)
  end
end
