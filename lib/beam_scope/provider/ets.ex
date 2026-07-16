defmodule BeamScope.Provider.ETS do
  @moduledoc """
  Domain provider for ETS usage (ADR-0004/0008).

  `poll/0` enumerates `:ets.all/0`, totals table count and memory, and finds the top-N
  largest tables by memory (bound with `config :beam_scope, top_n: N`, default 5).
  `aggregate/4` stores the latest summary and `snapshot/1` builds a `BeamScope.ETS`.

  Memory is reported by ETS in words and converted to bytes with the emulator word size.
  Tables can vanish mid-scan (`:ets.info/2` returns `:undefined`); those are skipped.
  """

  @behaviour BeamScope.DomainProvider

  alias BeamScope.ETS, as: ETSModel

  @summary [:ets, :summary]

  @impl true
  def sources, do: [@summary]

  @impl true
  def poll do
    # Read the word size at runtime (not compile time) so a build cross-compiled on a
    # different word-size emulator still reports correct byte counts.
    word_size = :erlang.system_info(:wordsize)

    tables =
      for tid <- :ets.all(),
          memory_words = :ets.info(tid, :memory),
          memory_words != :undefined do
        %{
          name: :ets.info(tid, :name),
          memory_bytes: memory_words * word_size,
          size: safe_info(tid, :size)
        }
      end

    measurements = %{
      table_count: length(tables),
      memory_bytes: tables |> Enum.map(& &1.memory_bytes) |> Enum.sum(),
      largest: tables |> Enum.sort_by(& &1.memory_bytes, :desc) |> Enum.take(top_n())
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

    ets = %ETSModel{
      table_count: Map.get(s, :table_count, 0),
      memory_bytes: Map.get(s, :memory_bytes, 0),
      largest: Map.get(s, :largest, [])
    }

    [ets]
  end

  defp safe_info(tid, key) do
    case :ets.info(tid, key) do
      :undefined -> 0
      value -> value
    end
  end

  defp top_n, do: Application.get_env(:beam_scope, :top_n, 5)

  defp ets_get(acc, key, default) do
    case :ets.lookup(acc, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
