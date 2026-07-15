defmodule BeamScope.Provider.ETSTest do
  use ExUnit.Case, async: true

  alias BeamScope.ETS, as: ETSModel
  alias BeamScope.Provider.ETS, as: Provider

  @summary [:ets, :summary]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  test "aggregate/4 stores the summary and snapshot/1 builds an ETS struct", %{acc: acc} do
    measurements = %{
      table_count: 3,
      memory_bytes: 4_096,
      largest: [%{name: :some_table, memory_bytes: 4_096, size: 12}]
    }

    Provider.aggregate(@summary, measurements, %{}, acc)

    assert [%ETSModel{table_count: 3, memory_bytes: 4_096} = e] = Provider.snapshot(acc)
    assert [%{name: :some_table, size: 12}] = e.largest
  end

  test "poll/0 reports the live ETS tables, bounded by top_n" do
    handler_id = "ets-poll-#{inspect(make_ref())}"
    parent = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    # a table we create should be counted
    _tid = :ets.new(:beam_scope_ets_test_tbl, [:public, :named_table])

    :telemetry.attach(
      handler_id,
      @summary,
      fn _e, m, _meta, _cfg -> send(parent, {:m, m}) end,
      nil
    )

    Provider.poll()

    assert_receive {:m, m}
    assert m.table_count > 0
    assert m.memory_bytes > 0
    assert length(m.largest) <= Application.get_env(:beam_scope, :top_n, 5)
    # largest is sorted descending by memory
    mems = Enum.map(m.largest, & &1.memory_bytes)
    assert mems == Enum.sort(mems, :desc)
  end
end
