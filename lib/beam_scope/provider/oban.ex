defmodule BeamScope.Provider.Oban do
  @moduledoc """
  Domain provider for the Oban **background-job** surface (ADR-0004/0008).

  A purely *event-driven* provider (the `BeamScope.Provider.Phoenix` pattern): it has no
  `poll/0` and folds telemetry emitted by Oban itself — `[:oban, :job, :start]`,
  `[:oban, :job, :stop]` (a job that returned), and `[:oban, :job, :exception]` (a job that
  raised / errored). It references only telemetry event **atoms**, never an Oban module, so it
  carries no compile-time dependency and stays inert on a node that emits no such events.

  `aggregate/4` runs in the emitting **job process** (many run concurrently), so it does only
  atomic `:ets.update_counter/4` increments. Two kinds of counter are kept per queue:

    * `{:executing, queue}` — a **live gauge**: `+1` on `:start`, `-1` on `:stop`/`:exception`.
      This is the in-flight count *right now*, read as-is on the tick.
    * `{:completed, queue}` / `{:failed, queue}` — **monotonic** cumulative counters, never
      reset on the hot path. `snapshot/1` diffs them against a `{:prev, ...}` marker to produce
      the per-window deltas (exactly as the Phoenix provider windows its request counters).

  Nothing is reset on the hot path, so no increment is lost. If the provider is attached while
  jobs are mid-flight, an unmatched `:stop` can briefly drive a queue's gauge negative; the tick
  clamps it to zero (a display concern only).

  Framework provider, opt-in: add `{BeamScope.Provider.Oban, :oban}` to
  `config :beam_scope, :providers`. Queue backlog depth (available/retryable/scheduled) is
  cluster-shared DB state rather than telemetry and is intentionally out of this event-driven
  provider; it would be an optional `poll/0` gated on Oban being loaded, and is left as a
  follow-up.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.Oban, as: ObanModel

  @start [:oban, :job, :start]
  @stop [:oban, :job, :stop]
  @exception [:oban, :job, :exception]

  @impl true
  def sources, do: [@start, @stop, @exception]

  @impl true
  def aggregate(@start, _measurements, meta, acc) do
    bump(acc, {:executing, queue_of(meta)}, 1)
    acc
  end

  def aggregate(@stop, _measurements, meta, acc) do
    queue = queue_of(meta)
    bump(acc, {:executing, queue}, -1)
    bump(acc, {:completed, queue}, 1)
    acc
  end

  def aggregate(@exception, _measurements, meta, acc) do
    queue = queue_of(meta)
    bump(acc, {:executing, queue}, -1)
    bump(acc, {:failed, queue}, 1)
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  @impl true
  def snapshot(acc) do
    executing = acc |> read_by_queue(:executing) |> clamp_nonneg()
    completed = read_by_queue(acc, :completed)
    failed = read_by_queue(acc, :failed)

    prev = ets_get(acc, :prev, %{completed: %{}, failed: %{}})
    :ets.insert(acc, {:prev, %{completed: completed, failed: failed}})

    oban = %ObanModel{
      executing: executing,
      completed: delta_by_queue(completed, prev.completed),
      failed: delta_by_queue(failed, prev.failed),
      completed_total: sum_values(completed),
      failed_total: sum_values(failed),
      window_ms: window_ms()
    }

    [oban]
  end

  # --- hot path (runs in the job process): atomic increments ---

  defp bump(acc, key, delta), do: :ets.update_counter(acc, key, delta, {key, 0})

  # Oban telemetry metadata carries the queue as a string (e.g. "imports"); normalize other
  # shapes and fall back to a constant so a queueless event never crashes the fold.
  defp queue_of(%{queue: queue}) when is_binary(queue), do: queue

  defp queue_of(%{queue: queue}) when is_atom(queue) and not is_nil(queue),
    do: Atom.to_string(queue)

  defp queue_of(_), do: "unknown"

  # --- tick (single process): read counters, window the cumulatives ---

  defp read_by_queue(acc, tag) do
    for {{^tag, queue}, count} <- :ets.match_object(acc, {{tag, :_}, :_}),
        into: %{},
        do: {queue, count}
  end

  defp delta_by_queue(current, prev) do
    Map.new(current, fn {queue, count} -> {queue, count - Map.get(prev, queue, 0)} end)
  end

  defp clamp_nonneg(map), do: Map.new(map, fn {queue, count} -> {queue, max(count, 0)} end)

  defp sum_values(map), do: map |> Map.values() |> Enum.sum()

  defp window_ms, do: Application.get_env(:beam_scope, :sync_interval, :timer.seconds(1))

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
