defmodule BeamScope.AggregatorTest do
  use ExUnit.Case, async: false

  alias BeamScope.{Aggregator, ClusterState}

  @moduletag :capture_log

  defmodule CrashyProvider do
    @moduledoc false
    @behaviour BeamScope.DomainProvider

    @event [:beam_scope_test, :crashy]

    def event, do: @event

    @impl true
    def sources, do: [@event]

    @impl true
    def aggregate(@event, %{mode: :boom}, _meta, _acc), do: raise("boom")

    def aggregate(@event, %{value: v}, _meta, acc) do
      :ets.insert(acc, {:latest, v})
      acc
    end

    @impl true
    def snapshot(acc) do
      case :ets.lookup(acc, :latest) do
        [{:latest, v}] -> [%{value: v}]
        [] -> []
      end
    end
  end

  setup do
    ClusterState.reset()
    :ok
  end

  test "a raising aggregate/4 does not silence the domain: the tick re-attaches the handler" do
    pid = start_supervised!({Aggregator, provider: CrashyProvider, domain: :crashy, interval: 25})

    :telemetry.execute(CrashyProvider.event(), %{value: 1}, %{})
    # :telemetry detaches a handler whose function raises — in the *emitting* process,
    # so the Aggregator itself never crashes and supervision alone would not recover.
    :telemetry.execute(CrashyProvider.event(), %{mode: :boom}, %{})

    eventually(fn -> entity_value() == 1 end)

    # The next tick's self-heal re-attached the handler, so new events flow again.
    eventually(fn ->
      :telemetry.execute(CrashyProvider.event(), %{value: 2}, %{})
      entity_value() == 2
    end)

    assert Process.alive?(pid)
  end

  defp entity_value do
    case ClusterState.get(Kernel.node()) do
      %{entities: %{crashy: [%{value: v} | _]}} -> v
      _ -> nil
    end
  end

  # Poll a function until it returns a truthy value, or fail after ~2s.
  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: flunk("condition not met within timeout")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
