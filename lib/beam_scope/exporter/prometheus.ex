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
      {"beamscope_ets_memory_bytes", "ETS memory in bytes.", ets_memory(nodes)},
      {"beamscope_mailbox_total_queued", "Total queued messages across all process mailboxes.",
       mailbox_total_queued(nodes)},
      {"beamscope_mailbox_max_queued", "Largest single process mailbox length.",
       mailbox_max_queued(nodes)},
      {"beamscope_mailbox_backlogged",
       "Processes with a mailbox at or above the backlog threshold.", mailbox_backlogged(nodes)},
      {"beamscope_mailbox_distribution", "Process count by mailbox-length bucket.",
       mailbox_distribution(nodes)},
      {"beamscope_phoenix_requests", "Phoenix HTTP requests in the last window.",
       gauge(nodes, :phoenix, & &1.requests)},
      {"beamscope_phoenix_errors", "Phoenix HTTP errors (5xx/exceptions) in the last window.",
       gauge(nodes, :phoenix, & &1.errors)},
      {"beamscope_phoenix_error_rate", "Phoenix HTTP error rate (0..1) in the last window.",
       phoenix_error_rate(nodes)},
      {"beamscope_phoenix_avg_latency_ms", "Phoenix average request latency (ms) in the window.",
       phoenix_avg_latency(nodes)},
      {"beamscope_phoenix_requests_total", "Phoenix HTTP requests since the node started.",
       gauge(nodes, :phoenix, & &1.requests_total)},
      {"beamscope_phoenix_errors_total", "Phoenix HTTP errors since the node started.",
       gauge(nodes, :phoenix, & &1.errors_total)},
      {"beamscope_phoenix_status", "Phoenix responses by status class in the last window.",
       phoenix_status(nodes)},
      {"beamscope_phoenix_latency", "Phoenix requests by latency bucket (ms) in the window.",
       phoenix_latency(nodes)}
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

  defp mailbox_total_queued(nodes), do: gauge(nodes, :mailbox, & &1.total_queued)
  defp mailbox_max_queued(nodes), do: gauge(nodes, :mailbox, & &1.max_queued)

  defp mailbox_backlogged(nodes) do
    for n <- nodes,
        m = first(n, :mailbox),
        m != nil,
        do: {[node: n.node, threshold: m.backlog_threshold], m.backlogged}
  end

  defp mailbox_distribution(nodes) do
    for n <- nodes,
        m = first(n, :mailbox),
        m != nil,
        {label, count} <- mailbox_buckets(m.distribution),
        is_number(count),
        do: {[node: n.node, bucket: label], count}
  end

  defp mailbox_buckets(distribution) do
    for label <- ~w(0 1-9 10-99 100-999 1000+), do: {label, Map.get(distribution, label, 0)}
  end

  defp phoenix_error_rate(nodes) do
    for n <- nodes,
        p = first(n, :phoenix),
        p != nil,
        is_float(p.error_rate),
        do: {[node: n.node], p.error_rate}
  end

  defp phoenix_avg_latency(nodes) do
    for n <- nodes,
        p = first(n, :phoenix),
        p != nil,
        is_float(p.avg_latency_ms),
        do: {[node: n.node], p.avg_latency_ms}
  end

  defp phoenix_status(nodes) do
    for n <- nodes,
        p = first(n, :phoenix),
        p != nil,
        {class, count} <- Enum.sort(p.status_classes),
        is_number(count),
        do: {[node: n.node, class: class], count}
  end

  defp phoenix_latency(nodes) do
    for n <- nodes,
        p = first(n, :phoenix),
        p != nil,
        {label, count} <- phoenix_latency_buckets(p.latency_distribution),
        is_number(count),
        do: {[node: n.node, bucket: label], count}
  end

  defp phoenix_latency_buckets(distribution) do
    for label <- ~w(0-10 10-50 50-200 200-1000 1000+),
        do: {label, Map.get(distribution, label, 0)}
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
