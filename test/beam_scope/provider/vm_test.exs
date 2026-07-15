defmodule BeamScope.Provider.VMTest do
  use ExUnit.Case, async: true

  alias BeamScope.Provider.VM, as: Provider
  alias BeamScope.VM

  setup do
    acc = :ets.new(:acc, [:public, :set])
    {:ok, acc: acc}
  end

  test "aggregate/4 folds the latest readings and snapshot/1 builds a VM struct", %{acc: acc} do
    Provider.aggregate(
      [:vm, :memory],
      %{total: 100, processes: 40, binary: 5, ets: 3, atom: 2},
      %{},
      acc
    )

    Provider.aggregate([:vm, :run_queue], %{total: 9}, %{}, acc)

    assert [%VM{} = vm] = Provider.snapshot(acc)
    assert vm.memory == %{total: 100, processes: 40, binary: 5, ets: 3, atom: 2}
    assert vm.run_queue == 9
    assert is_integer(vm.uptime_ms)
    assert is_binary(vm.otp_release)
  end

  test "snapshot/1 tolerates an empty accumulator", %{acc: acc} do
    assert [%VM{run_queue: 0, memory: %{total: nil}}] = Provider.snapshot(acc)
  end

  test "aggregate/4 ignores unknown events", %{acc: acc} do
    assert Provider.aggregate([:vm, :unknown], %{x: 1}, %{}, acc) == acc
    assert :ets.lookup(acc, :memory) == []
  end

  test "poll/0 emits the declared VM telemetry events" do
    ref = make_ref()
    handler_id = "vm-poll-test-#{inspect(ref)}"
    parent = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach_many(
      handler_id,
      Provider.sources(),
      fn event, measurements, _meta, _cfg -> send(parent, {ref, event, measurements}) end,
      nil
    )

    Provider.poll()

    assert_receive {^ref, [:vm, :memory], %{total: total}} when is_integer(total)
    assert_receive {^ref, [:vm, :run_queue], %{total: rq}} when is_integer(rq)
  end
end
