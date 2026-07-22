defmodule BeamScope.Provider.Phoenix do
  @moduledoc """
  Domain provider for the Phoenix **HTTP request** surface (ADR-0004/0008).

  This is the first *purely event-driven* provider: it has no `poll/0` and folds telemetry
  emitted by Phoenix itself — `[:phoenix, :endpoint, :stop]` (a completed request) and
  `[:phoenix, :endpoint, :exception]` (an uncaught error, which emits `:exception` *instead*
  of `:stop`). It references only telemetry event **atoms**, never a Phoenix module, so it
  carries no compile-time dependency and stays inert on a node that emits no such events.

  `aggregate/4` runs in the emitting **request process** — one per request, so many run
  concurrently. It therefore does only atomic `:ets.update_counter/4` increments into
  **monotonic cumulative** counters (the 4-arg default-object form avoids a missing-key
  crash under concurrent first-writers). `snapshot/1` runs single-threaded on the tick and
  is the sole reader/writer of the `{:prev, ...}` marker, computing per-window deltas
  (`current - prev`). Nothing is ever reset on the hot path, so no increment can be lost.

  Latency uses a fixed-bucket histogram (the `BeamScope.Provider.Mailbox` pattern) plus an
  average derived from a duration-sum delta — an exact windowed max is not achievable
  lock-free (ETS has no atomic max), and the histogram covers the same need. The struct also
  exposes per-node monotonic `requests_total`/`errors_total` (like `BeamScope.VM.uptime_ms`)
  so Prometheus `rate()` has a counter to work on.

  Framework provider, opt-in: add `{BeamScope.Provider.Phoenix, :phoenix}` to
  `config :beam_scope, :providers`. On the first tick, `:prev` is absent (zeros), so the
  first window reports activity since the aggregator started; negligible on a fresh node.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.Phoenix, as: PhoenixModel

  @stop [:phoenix, :endpoint, :stop]
  @exception [:phoenix, :endpoint, :exception]

  @latency_buckets ~w(0-10 10-50 50-200 200-1000 1000+)
  @status_classes ~w(2xx 3xx 4xx 5xx)

  @impl true
  def sources, do: [@stop, @exception]

  @impl true
  def aggregate(@stop, measurements, metadata, acc) do
    status = status_of(metadata)
    record(acc, duration_of(measurements), status, server_error?(status))
    acc
  end

  def aggregate(@exception, measurements, metadata, acc) do
    # An uncaught error emits :exception (never :stop), so it is always an error; if the
    # conn didn't carry a status, attribute it to 5xx.
    record(acc, duration_of(measurements), status_of(metadata) || 500, true)
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  @impl true
  def snapshot(acc) do
    current = read_cumulative(acc)
    prev = ets_get(acc, :prev, zeroed_cumulative())
    :ets.insert(acc, {:prev, current})

    dreq = current.requests - prev.requests
    derr = current.errors - prev.errors
    dsum = current.dur_sum - prev.dur_sum

    phoenix = %PhoenixModel{
      requests: dreq,
      errors: derr,
      error_rate: rate(derr, dreq),
      avg_latency_ms: avg_latency(dsum, dreq),
      latency_distribution: bucket_delta(current.latency, prev.latency, @latency_buckets),
      status_classes: bucket_delta(current.status, prev.status, @status_classes),
      window_ms: window_ms(),
      requests_total: current.requests,
      errors_total: current.errors
    }

    [phoenix]
  end

  # --- hot path (runs in the request process): atomic increments only ---

  defp record(acc, duration, status, error?) do
    :ets.update_counter(acc, :requests_total, 1, {:requests_total, 0})
    :ets.update_counter(acc, :dur_native_sum, duration, {:dur_native_sum, 0})
    if error?, do: :ets.update_counter(acc, :errors_total, 1, {:errors_total, 0})

    if class = status_class(status),
      do: :ets.update_counter(acc, {:status, class}, 1, {{:status, class}, 0})

    bucket = lat_bucket(System.convert_time_unit(duration, :native, :millisecond))
    :ets.update_counter(acc, {:lat, bucket}, 1, {{:lat, bucket}, 0})
    :ok
  end

  defp duration_of(%{duration: d}) when is_integer(d), do: d
  defp duration_of(_), do: 0

  defp status_of(%{conn: %{status: status}}) when is_integer(status), do: status
  defp status_of(_), do: nil

  defp server_error?(status) when is_integer(status) and status >= 500, do: true
  defp server_error?(_), do: false

  defp status_class(status) when is_integer(status) and status in 200..299, do: "2xx"
  defp status_class(status) when is_integer(status) and status in 300..399, do: "3xx"
  defp status_class(status) when is_integer(status) and status in 400..499, do: "4xx"
  defp status_class(status) when is_integer(status) and status >= 500, do: "5xx"
  defp status_class(_), do: nil

  defp lat_bucket(ms) when ms < 10, do: "0-10"
  defp lat_bucket(ms) when ms < 50, do: "10-50"
  defp lat_bucket(ms) when ms < 200, do: "50-200"
  defp lat_bucket(ms) when ms < 1000, do: "200-1000"
  defp lat_bucket(_ms), do: "1000+"

  # --- tick (single process): read cumulatives, compute deltas ---

  defp read_cumulative(acc) do
    %{
      requests: counter(acc, :requests_total),
      errors: counter(acc, :errors_total),
      dur_sum: counter(acc, :dur_native_sum),
      latency: Map.new(@latency_buckets, &{&1, counter(acc, {:lat, &1})}),
      status: Map.new(@status_classes, &{&1, counter(acc, {:status, &1})})
    }
  end

  defp zeroed_cumulative do
    %{
      requests: 0,
      errors: 0,
      dur_sum: 0,
      latency: Map.new(@latency_buckets, &{&1, 0}),
      status: Map.new(@status_classes, &{&1, 0})
    }
  end

  defp bucket_delta(current, prev, labels) do
    Map.new(labels, fn label -> {label, Map.get(current, label, 0) - Map.get(prev, label, 0)} end)
  end

  defp rate(_num, 0), do: 0.0
  defp rate(num, denom), do: num / denom

  defp avg_latency(_dsum, 0), do: nil
  defp avg_latency(dsum, dreq), do: System.convert_time_unit(dsum, :native, :millisecond) / dreq

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
