defmodule BeamScope.Provider.LiveViewTest do
  use ExUnit.Case, async: false

  alias BeamScope.Provider.LiveView, as: Provider
  alias BeamScope.Provider.LiveView.SocketMonitor
  alias BeamScope.LiveView

  @mount_stop [:phoenix, :live_view, :mount, :stop]
  @event_stop [:phoenix, :live_view, :handle_event, :stop]
  @event_exception [:phoenix, :live_view, :handle_event, :exception]

  setup do
    {:ok, acc: :ets.new(:acc, [:public, :set])}
  end

  defp event(acc, ms) do
    duration = System.convert_time_unit(ms, :millisecond, :native)
    Provider.aggregate(@event_stop, %{duration: duration}, %{}, acc)
  end

  test "folds mounts and handle_events into a windowed model", %{acc: acc} do
    Provider.aggregate(@mount_stop, %{}, %{}, acc)
    event(acc, 5)
    event(acc, 30)
    event(acc, 250)
    Provider.aggregate(@event_exception, %{duration: 0}, %{}, acc)

    assert [%LiveView{} = lv] = Provider.snapshot(acc)
    assert lv.mounts == 1
    # 3 stops + 1 exception
    assert lv.handle_events == 4
    assert is_float(lv.avg_latency_ms)

    assert lv.latency_distribution == %{
             "0-10" => 2,
             "10-50" => 1,
             "50-200" => 0,
             "200-1000" => 1,
             "1000+" => 0
           }
  end

  test "windows on the delta since the previous tick", %{acc: acc} do
    Provider.aggregate(@mount_stop, %{}, %{}, acc)
    event(acc, 5)
    assert [%LiveView{mounts: 1, handle_events: 1}] = Provider.snapshot(acc)

    # a quiet window reports zeros
    assert [%LiveView{mounts: 0, handle_events: 0}] = Provider.snapshot(acc)

    event(acc, 5)
    assert [%LiveView{mounts: 0, handle_events: 1}] = Provider.snapshot(acc)
  end

  test "connected_sockets counts live sessions and drops them on exit", %{acc: acc} do
    SocketMonitor.ensure_started()
    :ets.insert(:beam_scope_live_sockets, {:count, 0})

    # a real, connected socket: the mount span runs in a process that we let stay alive
    parent = self()

    socket_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    # simulate the mount telemetry firing *inside* the LiveView process, with a transport pid
    task =
      Task.async(fn ->
        # emulate aggregate running in the socket process by tracking that pid directly
        SocketMonitor.track(socket_pid)
        send(parent, :tracked)
      end)

    assert_receive :tracked
    Task.await(task)
    # allow the cast to be processed
    _ = SocketMonitor.count()
    assert eventually(fn -> SocketMonitor.count() == 1 end)

    assert [%LiveView{connected_sockets: 1}] = Provider.snapshot(acc)

    send(socket_pid, :stop)
    assert eventually(fn -> SocketMonitor.count() == 0 end)
    assert [%LiveView{connected_sockets: 0}] = Provider.snapshot(acc)
  end

  test "a disconnected mount (no transport pid) is not counted as a live socket", %{acc: acc} do
    SocketMonitor.ensure_started()
    :ets.insert(:beam_scope_live_sockets, {:count, 0})

    Provider.aggregate(@mount_stop, %{}, %{socket: %{transport_pid: nil}}, acc)
    _ = SocketMonitor.count()

    assert [%LiveView{mounts: 1, connected_sockets: 0}] = Provider.snapshot(acc)
  end

  test "tolerates an empty accumulator", %{acc: acc} do
    assert [%LiveView{} = lv] = Provider.snapshot(acc)
    assert lv.mounts == 0
    assert lv.handle_events == 0
    assert lv.avg_latency_ms == nil
    assert map_size(lv.latency_distribution) == 5
    assert lv.window_ms == Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))
  end

  defp eventually(fun, tries \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, tries - 1)
    end
  end
end
