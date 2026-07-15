defmodule BeamScope.Exporter.Dashboard do
  @moduledoc """
  Dashboard exporter (ADR-0007) — a stateless adapter that renders the cluster runtime
  model as a small, self-contained HTML page for human consumption.

  Like the Prometheus exporter it reads `BeamScope.ClusterState` on each request and holds
  no state of its own. The page auto-refreshes so it stays live without any JavaScript or
  a LiveView/Phoenix dependency (a LiveDashboard page remains a natural future exporter).

  `render/1` is pure; `page/0` reads the live model. Serve it via
  `BeamScope.Exporter.Router`.
  """

  alias BeamScope.ClusterState

  @refresh_seconds 2

  @doc "Render the live cluster model as an HTML page (binary)."
  @spec page() :: binary()
  def page, do: render(ClusterState.nodes()) |> IO.iodata_to_binary()

  @doc "Render the given nodes as a full HTML document (iodata)."
  @spec render([BeamScope.ClusterNode.t()]) :: iodata()
  def render(nodes) do
    [
      "<!doctype html><html><head><meta charset=\"utf-8\">",
      "<meta http-equiv=\"refresh\" content=\"",
      Integer.to_string(@refresh_seconds),
      "\">",
      "<title>BeamScope</title><style>",
      css(),
      "</style></head><body>",
      "<h1>BeamScope <span class=\"sub\">cluster runtime model</span></h1>",
      "<table><thead><tr>",
      th(~w(Node Liveness VM memory Run queue Uptime Sched util Processes ETS)),
      "</tr></thead><tbody>",
      nodes |> Enum.sort_by(& &1.node) |> Enum.map(&row/1),
      "</tbody></table>",
      "<p class=\"foot\">",
      Integer.to_string(length(nodes)),
      " node(s) · refreshes every ",
      Integer.to_string(@refresh_seconds),
      "s</p></body></html>"
    ]
  end

  defp row(node) do
    vm = first(node, :vm)
    sched = first(node, :scheduler)
    procs = first(node, :processes)
    ets = first(node, :ets)

    [
      "<tr><td class=\"mono\">",
      esc(to_string(node.node)),
      "</td>",
      "<td>",
      liveness_badge(node.liveness),
      "</td>",
      td(vm && mb(vm.memory[:total])),
      td(vm && Integer.to_string(vm.run_queue)),
      td(vm && duration(vm.uptime_ms)),
      td(sched && percent(sched.utilization)),
      td(procs && [Integer.to_string(procs.count), " / ", Integer.to_string(procs.limit)]),
      td(ets && [Integer.to_string(ets.table_count), " · ", mb(ets.memory_bytes)]),
      "</tr>"
    ]
  end

  defp liveness_badge(liveness) do
    ["<span class=\"badge ", Atom.to_string(liveness), "\">", Atom.to_string(liveness), "</span>"]
  end

  defp th(headers), do: Enum.map(headers, &["<th>", esc(&1), "</th>"])
  defp td(nil), do: "<td class=\"nil\">—</td>"
  defp td(content), do: ["<td>", content, "</td>"]

  defp mb(nil), do: "—"

  defp mb(bytes) when is_integer(bytes),
    do: [:erlang.float_to_binary(bytes / 1_048_576, decimals: 1), " MB"]

  defp percent(nil), do: "—"

  defp percent(fraction) when is_float(fraction),
    do: [:erlang.float_to_binary(fraction * 100, decimals: 1), "%"]

  defp duration(ms) when is_integer(ms), do: [Integer.to_string(div(ms, 1000)), "s"]
  defp duration(_), do: "—"

  defp first(%{entities: entities}, domain) do
    case Map.get(entities, domain) do
      [entity | _] -> entity
      _ -> nil
    end
  end

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp css do
    """
    body{font:14px/1.5 system-ui,sans-serif;margin:2rem;color:#1a1a1a;background:#fafafa}
    h1{font-size:1.4rem;margin:0 0 1rem}.sub{color:#888;font-weight:400;font-size:1rem}
    table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
    th,td{padding:.5rem .75rem;text-align:left;border-bottom:1px solid #eee}
    th{background:#f4f4f5;font-size:.8rem;text-transform:uppercase;letter-spacing:.03em;color:#666}
    .mono{font-family:ui-monospace,monospace}.nil{color:#bbb}
    .badge{padding:.1rem .5rem;border-radius:1rem;font-size:.75rem;font-weight:600}
    .badge.live{background:#dcfce7;color:#166534}.badge.stale{background:#fef9c3;color:#854d0e}
    .badge.expired{background:#fee2e2;color:#991b1b}
    .foot{color:#999;margin-top:1rem;font-size:.85rem}
    @media(prefers-color-scheme:dark){body{background:#18181b;color:#e4e4e7}
    table{background:#27272a;box-shadow:none}th{background:#3f3f46;color:#a1a1aa}
    th,td{border-color:#3f3f46}.sub,.foot{color:#71717a}}
    """
  end
end
