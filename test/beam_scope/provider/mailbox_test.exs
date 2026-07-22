defmodule BeamScope.Provider.MailboxTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.Mailbox, as: Provider
  alias BeamScope.Mailbox

  @summary [:mailbox, :summary]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  test "aggregate/4 stores the summary and snapshot/1 builds a Mailbox", %{acc: acc} do
    measurements = %{
      total_queued: 42,
      max_queued: 30,
      backlogged: 2,
      backlog_threshold: 1000,
      distribution: %{"0" => 5, "1-9" => 3, "10-99" => 1, "100-999" => 0, "1000+" => 1}
    }

    Provider.aggregate(@summary, measurements, %{}, acc)

    assert [%Mailbox{} = mb] = Provider.snapshot(acc)
    assert mb.total_queued == 42
    assert mb.max_queued == 30
    assert mb.backlogged == 2
    assert mb.backlog_threshold == 1000
    assert mb.distribution == %{"0" => 5, "1-9" => 3, "10-99" => 1, "100-999" => 0, "1000+" => 1}
  end

  test "snapshot/1 tolerates an empty accumulator", %{acc: acc} do
    assert [%Mailbox{} = mb] = Provider.snapshot(acc)
    assert mb.total_queued == 0
    assert mb.max_queued == 0
    assert mb.backlogged == 0
    assert mb.backlog_threshold == 0
    assert map_size(mb.distribution) == 5
  end

  test "aggregate/4 ignores unknown events", %{acc: acc} do
    assert Provider.aggregate([:mailbox, :unknown], %{x: 1}, %{}, acc) == acc
  end

  test "poll/0 emits a bounded, real summary of the live system" do
    handler_id = "mailbox-poll-#{inspect(make_ref())}"
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
    assert m.total_queued >= 0
    assert m.max_queued >= 0
    assert m.backlogged >= 0

    assert m.backlog_threshold ==
             Application.get_env(:beam_scope, :mailbox_backlog_threshold, 1000)

    assert m.max_queued <= m.total_queued

    assert Enum.sort(Map.keys(m.distribution)) ==
             Enum.sort(~w(0 1-9 10-99 100-999 1000+))

    assert Enum.all?(Map.values(m.distribution), &(&1 >= 0))
    # there is always at least one live process
    assert Enum.sum(Map.values(m.distribution)) > 0
  end
end
