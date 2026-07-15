defmodule BeamScope.Exporter.Prometheus do
  @moduledoc """
  Prometheus exporter (ADR-0007) — a stateless adapter that renders the cluster runtime
  model to the Prometheus text exposition format **at scrape time**.

  Reading `BeamScope.ClusterState` on each scrape (rather than feeding a stateful metrics
  reporter) means node expiry is reflected correctly: a departed node's series simply stop
  appearing, instead of a last value lingering forever.

  Every series is labelled by `node`, so any node exports a view of the whole cluster.
  `render/1` is pure (dependency-free) and independently testable; `scrape/0` reads the
  live model. To serve it, use `BeamScope.Exporter.Router` (or call `scrape/0` from a host
  controller).
  """

  alias BeamScope.ClusterState

  @doc "Render the live cluster model as Prometheus text (binary)."
  @spec scrape() :: binary()
  def scrape, do: render(ClusterState.nodes()) |> IO.iodata_to_binary()

  @doc "Render the given nodes as Prometheus text exposition (iodata)."
  @spec render([BeamScope.ClusterNode.t()]) :: iodata()
  def render(nodes) do
    [
      {"beamscope_node_up", "1 if the node is currently live, else 0.", node_up(nodes)},
      {"beamscope_vm_memory_bytes", "VM memory in bytes by kind.", vm_memory(nodes)},
      {"beamscope_vm_run_queue", "Total run queue length.", vm_run_queue(nodes)},
      {"beamscope_vm_uptime_ms", "VM uptime in milliseconds.", vm_uptime(nodes)},
      {"beamscope_scheduler_utilization", "Overall scheduler utilization (0..1).",
       scheduler_utilization(nodes)},
      {"beamscope_scheduler_online", "Number of online normal schedulers.",
       scheduler_online(nodes)},
      {"beamscope_process_count", "Current process count.", process_count(nodes)},
      {"beamscope_process_limit", "Maximum process count.", process_limit(nodes)},
      {"beamscope_ets_table_count", "Number of ETS tables.", ets_table_count(nodes)},
      {"beamscope_ets_memory_bytes", "ETS memory in bytes.", ets_memory(nodes)}
    ]
    |> Enum.map(fn {name, help, series} -> family(name, help, series) end)
  end

  # --- series extraction ---

  defp node_up(nodes) do
    for n <- nodes, do: {[node: n.node], if(n.liveness == :live, do: 1, else: 0)}
  end

  defp vm_memory(nodes) do
    for n <- nodes,
        vm = first(n, :vm),
        vm != nil,
        {kind, value} <- memory_kinds(vm.memory),
        is_number(value),
        do: {[node: n.node, kind: kind], value}
  end

  defp memory_kinds(memory) do
    [
      {"total", memory[:total]},
      {"processes", memory[:processes]},
      {"binary", memory[:binary]},
      {"ets", memory[:ets]},
      {"atom", memory[:atom]}
    ]
  end

  defp vm_run_queue(nodes), do: gauge(nodes, :vm, & &1.run_queue)
  defp vm_uptime(nodes), do: gauge(nodes, :vm, & &1.uptime_ms)
  defp scheduler_online(nodes), do: gauge(nodes, :scheduler, & &1.online)
  defp process_count(nodes), do: gauge(nodes, :processes, & &1.count)
  defp process_limit(nodes), do: gauge(nodes, :processes, & &1.limit)
  defp ets_table_count(nodes), do: gauge(nodes, :ets, & &1.table_count)
  defp ets_memory(nodes), do: gauge(nodes, :ets, & &1.memory_bytes)

  defp scheduler_utilization(nodes) do
    for n <- nodes,
        s = first(n, :scheduler),
        s != nil,
        is_float(s.utilization),
        do: {[node: n.node], s.utilization}
  end

  # Generic single-gauge series for an entity field.
  defp gauge(nodes, domain, fun) do
    for n <- nodes,
        entity = first(n, domain),
        entity != nil,
        value = fun.(entity),
        is_number(value),
        do: {[node: n.node], value}
  end

  defp first(%{entities: entities}, domain) do
    case Map.get(entities, domain) do
      [entity | _] -> entity
      _ -> nil
    end
  end

  # --- text formatting ---

  defp family(name, help, series) do
    [
      "# HELP ",
      name,
      ?\s,
      help,
      ?\n,
      "# TYPE ",
      name,
      " gauge\n",
      for {labels, value} <- series do
        [name, labels(labels), ?\s, format(value), ?\n]
      end
    ]
  end

  defp labels([]), do: []

  defp labels(pairs) do
    inner =
      pairs
      |> Enum.map(fn {key, value} ->
        [Atom.to_string(key), "=\"", escape(to_string(value)), ?"]
      end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp format(value) when is_integer(value), do: Integer.to_string(value)
  defp format(value) when is_float(value), do: Float.to_string(value)
end
