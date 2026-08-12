defmodule BeamScope.Provider.LiveView do
  @moduledoc """
  Domain provider for the Phoenix **LiveView** surface (ADR-0004/0008).

  Two halves, both opt-in and carrying no compile-time Phoenix dependency (it references only
  telemetry event **atoms**, like `BeamScope.Provider.Phoenix`):

    * **Event metrics (telemetry-only):** it folds `[:phoenix, :live_view, :mount, :stop]` and
      `[:phoenix, :live_view, :handle_event, :stop | :exception]` into monotonic counters and a
      latency histogram on the hot path (atomic `:ets.update_counter/4` in the emitting LiveView
      process). `snapshot/1` diffs a `{:prev, ...}` marker to produce per-window deltas — the
      exact windowing the Phoenix provider uses.

    * **Connected-socket gauge (pid monitoring):** LiveView has no "disconnected" telemetry, so
      a live session count needs pid-`:DOWN` tracking. On each *connected* mount, the fold hands
      the LiveView process to `BeamScope.Provider.LiveView.SocketMonitor`, which monitors it and
      keeps the current count; `snapshot/1` reads that count. `setup/0` starts the monitor.

  Framework provider, opt-in: add `{BeamScope.Provider.LiveView, :live_view}` to
  `config :beam_scope, :providers`.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.LiveView, as: LiveViewModel
  alias BeamScope.Provider.LiveView.SocketMonitor

  @mount_stop [:phoenix, :live_view, :mount, :stop]
  @event_stop [:phoenix, :live_view, :handle_event, :stop]
  @event_exception [:phoenix, :live_view, :handle_event, :exception]

  @latency_buckets ~w(0-10 10-50 50-200 200-1000 1000+)

  @impl true
  def setup, do: SocketMonitor.ensure_started()

  @impl true
  def sources, do: [@mount_stop, @event_stop, @event_exception]

  @impl true
  def aggregate(@mount_stop, _measurements, metadata, acc) do
    :ets.update_counter(acc, :mounts, 1, {:mounts, 0})
    # Count only *connected* sockets; the initial dead render also emits mount but has no
    # transport. The mount span runs in the LiveView process, so self() is the process that
    # dies on disconnect — the right thing to monitor.
    if connected?(metadata), do: SocketMonitor.track(self())
    acc
  end

  def aggregate(@event_stop, measurements, _metadata, acc) do
    record_event(acc, duration_of(measurements))
    acc
  end

  def aggregate(@event_exception, measurements, _metadata, acc) do
    record_event(acc, duration_of(measurements))
    acc
  end

  def aggregate(_event, _measurements, _metadata, acc), do: acc

  @impl true
  def snapshot(acc) do
    current = read_cumulative(acc)
    prev = ets_get(acc, :prev, zeroed_cumulative())
    :ets.insert(acc, {:prev, current})

    devents = current.handle_events - prev.handle_events
    dsum = current.dur_sum - prev.dur_sum

    live_view = %LiveViewModel{
      mounts: current.mounts - prev.mounts,
      handle_events: devents,
      avg_latency_ms: avg_latency(dsum, devents),
      latency_distribution: bucket_delta(current.latency, prev.latency, @latency_buckets),
      connected_sockets: SocketMonitor.count(),
      window_ms: window_ms()
    }

    [live_view]
  end

  # --- hot path (runs in the LiveView process): atomic increments ---

  defp record_event(acc, duration) do
    :ets.update_counter(acc, :handle_events, 1, {:handle_events, 0})
    :ets.update_counter(acc, :dur_native_sum, duration, {:dur_native_sum, 0})
    ms = System.convert_time_unit(duration, :native, :millisecond)
    bucket = lat_bucket(ms)
    :ets.update_counter(acc, {:lat, bucket}, 1, {{:lat, bucket}, 0})
    :ok
  end

  # A connected LiveView carries a transport pid; the initial disconnected render does not.
  defp connected?(%{socket: %{transport_pid: pid}}) when is_pid(pid), do: true
  defp connected?(_), do: false

  defp duration_of(%{duration: d}) when is_integer(d), do: d
  defp duration_of(_), do: 0

  defp lat_bucket(ms) when ms < 10, do: "0-10"
  defp lat_bucket(ms) when ms < 50, do: "10-50"
  defp lat_bucket(ms) when ms < 200, do: "50-200"
  defp lat_bucket(ms) when ms < 1000, do: "200-1000"
  defp lat_bucket(_ms), do: "1000+"

  # --- tick (single process): read cumulatives, compute deltas ---

  defp read_cumulative(acc) do
    %{
      mounts: counter(acc, :mounts),
      handle_events: counter(acc, :handle_events),
      dur_sum: counter(acc, :dur_native_sum),
      latency: Map.new(@latency_buckets, &{&1, counter(acc, {:lat, &1})})
    }
  end

  defp zeroed_cumulative do
    %{
      mounts: 0,
      handle_events: 0,
      dur_sum: 0,
      latency: Map.new(@latency_buckets, &{&1, 0})
    }
  end

  defp bucket_delta(current, prev, labels) do
    Map.new(labels, fn label -> {label, Map.get(current, label, 0) - Map.get(prev, label, 0)} end)
  end

  defp avg_latency(_dsum, 0), do: nil

  defp avg_latency(dsum, devents),
    do: System.convert_time_unit(dsum, :native, :millisecond) / devents

  defp window_ms, do: Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))

  defp counter(acc, key) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
