defmodule BeamScope.Provider.Processes do
  @moduledoc """
  Domain provider for the process population (ADR-0004/0008).

  `poll/0` reads the total process count/limit and does a full scan of `Process.list/0`
  to find the top-N processes by mailbox length and by memory (bound with
  `config :beam_scope, top_n: N`, default 5). `aggregate/4` stores the latest summary and
  `snapshot/1` builds a `BeamScope.ProcessSummary`.

  The scan is O(process count) per tick (exact top-N). That is cheap on typical nodes but
  a known cost on very large ones; sampling/benchmarks are deferred to Inc 5
  (`docs/ROADMAP.md`).
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.ProcessSummary

  @summary [:process, :summary]

  @impl true
  def sources, do: [@summary]

  def poll do
    entries =
      for pid <- Process.list(),
          info = Process.info(pid, [:message_queue_len, :memory, :registered_name]),
          info != nil do
        %{
          pid: inspect(pid),
          name: registered_name(info[:registered_name]),
          mailbox: info[:message_queue_len],
          memory: info[:memory]
        }
      end

    measurements = %{
      count: :erlang.system_info(:process_count),
      limit: :erlang.system_info(:process_limit),
      top_mailboxes: top_by(entries, :mailbox),
      top_memory: top_by(entries, :memory)
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

    summary = %ProcessSummary{
      count: Map.get(s, :count, 0),
      limit: Map.get(s, :limit, 0),
      top_mailboxes: Map.get(s, :top_mailboxes, []),
      top_memory: Map.get(s, :top_memory, [])
    }

    [summary]
  end

  defp top_by(entries, key) do
    entries
    |> Enum.sort_by(&Map.fetch!(&1, key), :desc)
    |> Enum.take(top_n())
    |> Enum.map(fn e -> %{pid: e.pid, name: e.name, value: Map.fetch!(e, key)} end)
  end

  defp registered_name([]), do: nil
  defp registered_name(name) when is_atom(name), do: name
  defp registered_name(_), do: nil

  defp top_n, do: Application.get_env(:beam_scope, :top_n, 5)

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
