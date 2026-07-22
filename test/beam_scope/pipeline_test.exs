defmodule BeamScope.PipelineTest do
  @moduledoc """
  Inc 1 exit criterion: on a single node the full local core loop
  (Telemetry → ETS aggregation → snapshot → ClusterState) produces live VM state
  reachable through the public API.
  """
  use ExUnit.Case, async: false

  alias BeamScope.{ETS, Mailbox, ProcessSummary, Scheduler, VM}

  setup do
    BeamScope.ClusterState.reset()
    :ok
  end

  test "BeamScope.vm/1 reflects real, ticking VM state on the local node" do
    assert BeamScope.vm(Kernel.node()) == nil

    # Aggregation is disabled in test config; start it explicitly for this test.
    start_supervised!(BeamScope.Aggregation.Supervisor)

    # Wait for a snapshot that has actually been fed by a poll (the very first tick can
    # fire before the first poll populates the accumulator).
    vm =
      eventually(fn ->
        case BeamScope.vm(Kernel.node()) do
          %VM{memory: %{total: t}} = v when is_integer(t) -> v
          _ -> nil
        end
      end)

    assert %VM{} = vm
    assert vm.memory.total > 0
    assert is_integer(vm.uptime_ms) and vm.uptime_ms >= 0
    assert is_binary(vm.otp_release)

    # The model keeps ticking: a later snapshot bumps the node version.
    v1 = BeamScope.node(Kernel.node()).version

    v2 =
      eventually(fn -> with %{version: v} when v > v1 <- BeamScope.node(Kernel.node()), do: v end)

    assert v2 > v1
  end

  test "all MVP domains populate through the pipeline (Inc 3)" do
    start_supervised!(BeamScope.Aggregation.Supervisor)

    # Scheduler: counts appear immediately; utilization needs a second sample.
    sched = eventually(fn -> BeamScope.schedulers(Kernel.node()) end)
    assert %Scheduler{} = sched
    assert sched.count > 0 and sched.online > 0

    util =
      eventually(fn ->
        case BeamScope.schedulers(Kernel.node()) do
          %Scheduler{utilization: u} when is_float(u) -> u
          _ -> nil
        end
      end)

    assert is_float(util) and util >= 0.0 and util <= 1.0

    # Processes: wait for the first real scan (count > 0).
    procs =
      eventually(fn ->
        case BeamScope.processes(Kernel.node()) do
          %ProcessSummary{count: c} = p when c > 0 -> p
          _ -> nil
        end
      end)

    assert %ProcessSummary{} = procs
    assert procs.count > 0 and procs.limit > 0

    # ETS: wait for the first real scan (table_count > 0).
    ets =
      eventually(fn ->
        case BeamScope.ets(Kernel.node()) do
          %ETS{table_count: n} = e when n > 0 -> e
          _ -> nil
        end
      end)

    assert %ETS{} = ets
    assert ets.table_count > 0 and ets.memory_bytes > 0

    # Mailbox: wait for the first real scan (distribution populated by a poll).
    mailbox =
      eventually(fn ->
        case BeamScope.mailbox(Kernel.node()) do
          %Mailbox{backlog_threshold: t} = m when t > 0 -> m
          _ -> nil
        end
      end)

    assert %Mailbox{} = mailbox
    assert mailbox.total_queued >= 0
    assert mailbox.backlog_threshold > 0
    assert map_size(mailbox.distribution) == 5
  end

  # Poll a function until it returns a truthy value, or fail after ~2s.
  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: flunk("condition not met within timeout")

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      false ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
