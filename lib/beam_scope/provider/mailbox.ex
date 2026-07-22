defmodule BeamScope.Provider.Mailbox do
  @moduledoc """
  Domain provider for the mailbox distribution (ADR-0004/0008).

  `poll/0` does a single `Process.list/0` pass, folding every live process's
  `:message_queue_len` into a total, a running max, a backlog count (mailbox at or
  above `config :beam_scope, mailbox_backlog_threshold: N`, default 1000) and a fixed
  5-bucket histogram. `aggregate/4` stores the latest summary and `snapshot/1` builds a
  `BeamScope.Mailbox`.

  Unlike `BeamScope.Provider.Processes` (which owns per-process top-N), this provider
  owns the aggregate/distributional view. The scan is O(process count) per tick — cheap
  on typical nodes; sampling/benchmarks are deferred to Inc 5 (`docs/ROADMAP.md`).
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.Mailbox

  @summary [:mailbox, :summary]
  @buckets ~w(0 1-9 10-99 100-999 1000+)

  @impl true
  def sources, do: [@summary]

  @impl true
  def poll do
    threshold = backlog_threshold()

    acc = %{total: 0, max: 0, backlogged: 0, buckets: zeroed_distribution()}

    acc =
      Enum.reduce(Process.list(), acc, fn pid, acc ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} ->
            bucket = bucket(len)

            %{
              total: acc.total + len,
              max: max(acc.max, len),
              backlogged: acc.backlogged + if(len >= threshold, do: 1, else: 0),
              buckets: Map.update!(acc.buckets, bucket, &(&1 + 1))
            }

          nil ->
            acc
        end
      end)

    measurements = %{
      total_queued: acc.total,
      max_queued: acc.max,
      backlogged: acc.backlogged,
      backlog_threshold: threshold,
      distribution: acc.buckets
    }

    :telemetry.execute(@summary, measurements, %{})
    :ok
  end

  @impl true
  def aggregate(@summary, measurements, _meta, acc) do
    :ets.insert(acc, {:summary, measurements})
    acc
  end

  def aggregate(_event, _measurements, _meta, acc), do: acc

  @impl true
  def snapshot(acc) do
    s = ets_get(acc, :summary, %{})

    mailbox = %Mailbox{
      total_queued: Map.get(s, :total_queued, 0),
      max_queued: Map.get(s, :max_queued, 0),
      backlogged: Map.get(s, :backlogged, 0),
      backlog_threshold: Map.get(s, :backlog_threshold, 0),
      distribution: Map.get(s, :distribution, zeroed_distribution())
    }

    [mailbox]
  end

  defp bucket(0), do: "0"
  defp bucket(len) when len in 1..9, do: "1-9"
  defp bucket(len) when len in 10..99, do: "10-99"
  defp bucket(len) when len in 100..999, do: "100-999"
  defp bucket(_len), do: "1000+"

  defp zeroed_distribution, do: Map.new(@buckets, &{&1, 0})

  defp backlog_threshold, do: Application.get_env(:beam_scope, :mailbox_backlog_threshold, 1000)

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
