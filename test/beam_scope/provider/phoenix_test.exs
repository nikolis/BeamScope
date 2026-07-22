defmodule BeamScope.Provider.PhoenixTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Phoenix, as: Provider
  alias BeamScope.Phoenix
  alias BeamScope.Phoenix.NotableRequest

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
    assert p.top_slow == []
    assert p.recent_5xx == []
  end

  # --- notable requests (ADR-0010) ---

  test "top_slow samples only requests at/above the floor, sorted by latency desc", %{acc: acc} do
    stop(acc, 200, 5)
    stop(acc, 200, 49)
    stop(acc, 200, 60)
    stop(acc, 200, 300)
    stop(acc, 200, 120)

    assert [%Phoenix{} = p] = Provider.snapshot(acc)

    # sub-floor (5ms, 49ms) requests are dropped; the rest rank by latency desc
    assert Enum.map(p.top_slow, & &1.latency_ms) == [300, 120, 60]
    assert Enum.all?(p.top_slow, &match?(%NotableRequest{status: 200}, &1))
    # no router in the metadata fixture → the PII-free fallback template, never a concrete path
    assert Enum.all?(p.top_slow, &(&1.route == "(unmatched)"))
  end

  test "recent_5xx captures 5xx and exceptions, most-recent-first", %{acc: acc} do
    stop(acc, 500, 5)
    Process.sleep(2)
    stop(acc, 503, 5)
    Process.sleep(2)
    # exception with no conn is still an error, attributed to 500 with the fallback route
    Provider.aggregate(@exception, %{duration: 0}, %{}, acc)

    assert [%Phoenix{} = p] = Provider.snapshot(acc)

    assert length(p.recent_5xx) == 3
    # the exception was recorded last, so it heads the recency-ordered list
    assert [%NotableRequest{status: 500, route: "(unmatched)"} | _] = p.recent_5xx
    assert p.recent_5xx |> Enum.map(& &1.status) |> Enum.sort() == [500, 500, 503]
    # a fast (5ms) error is an error but not slow, so it never enters top_slow
    assert p.top_slow == []
  end

  test "notable samples are bounded to top_n regardless of volume", %{acc: acc} do
    for i <- 1..30, do: stop(acc, 500, 50 + i)

    assert [%Phoenix{} = p] = Provider.snapshot(acc)
    assert length(p.top_slow) == 5
    assert length(p.recent_5xx) == 5
  end

  test "notable samples are window-scoped and cleared each tick", %{acc: acc} do
    stop(acc, 500, 100)

    assert [%Phoenix{top_slow: [_], recent_5xx: [_]}] = Provider.snapshot(acc)
    # a subsequent tick with no activity starts from an empty sample
    assert [%Phoenix{top_slow: [], recent_5xx: []}] = Provider.snapshot(acc)
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
