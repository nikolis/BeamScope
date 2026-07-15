defmodule BeamScope.Provider.ProcessesTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Processes, as: Provider
  alias BeamScope.ProcessSummary

  @summary [:process, :summary]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  test "aggregate/4 stores the summary and snapshot/1 builds a ProcessSummary", %{acc: acc} do
    measurements = %{
      count: 5,
      limit: 10,
      top_mailboxes: [%{pid: "#PID<0.1.0>", name: :init, value: 3}],
      top_memory: [%{pid: "#PID<0.1.0>", name: :init, value: 999}]
    }

    Provider.aggregate(@summary, measurements, %{}, acc)

    assert [%ProcessSummary{count: 5, limit: 10} = s] = Provider.snapshot(acc)
    assert [%{name: :init, value: 3}] = s.top_mailboxes
    assert [%{name: :init, value: 999}] = s.top_memory
  end

  test "snapshot/1 tolerates an empty accumulator", %{acc: acc} do
    assert [%ProcessSummary{count: 0, top_mailboxes: [], top_memory: []}] = Provider.snapshot(acc)
  end

  test "poll/0 emits a bounded, real summary of the live system" do
    handler_id = "proc-poll-#{inspect(make_ref())}"
    parent = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      @summary,
      fn _e, m, _meta, _cfg -> send(parent, {:m, m}) end,
      nil
    )

    Provider.poll()

    assert_receive {:m, m}
    assert m.count > 0
    assert m.limit > 0
    assert length(m.top_memory) <= Application.get_env(:beam_scope, :top_n, 5)

    assert Enum.all?(
             m.top_memory,
             &match?(%{pid: p, value: v} when is_binary(p) and is_integer(v), &1)
           )

    # top_memory is sorted descending
    values = Enum.map(m.top_memory, & &1.value)
    assert values == Enum.sort(values, :desc)
  end
end
