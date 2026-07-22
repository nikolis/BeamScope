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
      th(
        ~w(Node Liveness VM memory Run queue Uptime Sched util Processes ETS Mailbox Backlog Phoenix)
      ),
      "</tr></thead><tbody>",
      nodes |> Enum.sort_by(& &1.node) |> Enum.map(&row/1),
      "</tbody></table>",
      notable_section(nodes),
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
    mailbox = first(node, :mailbox)
    phoenix = first(node, :phoenix)

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
      td(
        mailbox &&
          [
            Integer.to_string(mailbox.total_queued),
            " queued · max ",
            Integer.to_string(mailbox.max_queued)
          ]
      ),
      td(
        mailbox &&
          [
            Integer.to_string(mailbox.backlogged),
            " ≥ ",
            Integer.to_string(mailbox.backlog_threshold)
          ]
      ),
      td(
        phoenix &&
          [
            Integer.to_string(phoenix.requests_total),
            " req · ",
            Integer.to_string(phoenix.errors_total),
            " err · ",
            percent(phoenix.error_rate),
            " err rate · ",
            latency(phoenix.avg_latency_ms)
          ]
      ),
      "</tr>"
    ]
  end

  # Fleet-wide "notable requests" sample (ADR-0010), composed at read time: each node carries
  # only its own bounded top-N, so a cluster-wide view is produced here by concatenating every
  # node's list, re-sorting, and taking the top-N — never by a special merge in ClusterState
  # (Rule 5). The composed set is eventually-consistent and may differ between viewers.
  defp notable_section(nodes) do
    slow =
      nodes
      |> compose(:top_slow)
      |> Enum.sort_by(fn {_node, r} -> r.latency_ms end, :desc)
      |> Enum.take(top_n())

    errs =
      nodes
      |> compose(:recent_5xx)
      |> Enum.sort_by(fn {_node, r} -> r.at end, :desc)
      |> Enum.take(top_n())

    if slow == [] and errs == [] do
      []
    else
      [
        "<h2>Notable requests <span class=\"sub\">bounded sample · fleet-wide</span></h2>",
        "<div class=\"notable\">",
        notable_table("Slowest requests", ~w(Node Route Status Latency), slow, &slow_row/1),
        notable_table("Recent 5xx", ~w(Node Route Status Latency When), errs, &err_row/1),
        "</div>"
      ]
    end
  end

  defp compose(nodes, field) do
    for node <- nodes,
        p = first(node, :phoenix),
        p != nil,
        r <- Map.fetch!(p, field),
        do: {node.node, r}
  end

  defp notable_table(_title, _headers, [], _row_fun), do: []

  defp notable_table(title, headers, rows, row_fun) do
    [
      "<div><h3>",
      esc(title),
      "</h3><table><thead><tr>",
      th(headers),
      "</tr></thead><tbody>",
      Enum.map(rows, row_fun),
      "</tbody></table></div>"
    ]
  end

  defp slow_row({node, r}) do
    [
      "<tr><td class=\"mono\">",
      esc(to_string(node)),
      "</td><td class=\"mono\">",
      esc(r.route),
      "</td>",
      td(r.status && Integer.to_string(r.status)),
      td([Integer.to_string(r.latency_ms), " ms"]),
      "</tr>"
    ]
  end

  defp err_row({node, r}) do
    [
      "<tr><td class=\"mono\">",
      esc(to_string(node)),
      "</td><td class=\"mono\">",
      esc(r.route),
      "</td>",
      td(r.status && Integer.to_string(r.status)),
      td([Integer.to_string(r.latency_ms), " ms"]),
      td(clock(r.at)),
      "</tr>"
    ]
  end

  defp clock(at) when is_integer(at) and at > 0 do
    at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  defp clock(_), do: nil

  defp top_n, do: Application.get_env(:beam_scope, :top_n, 5)

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

  defp latency(nil), do: "—"
  defp latency(ms) when is_float(ms), do: [:erlang.float_to_binary(ms, decimals: 1), " ms"]

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
    h2{font-size:1.1rem;margin:1.75rem 0 .5rem}
    h3{font-size:.85rem;margin:.75rem 0 .35rem;color:#555;text-transform:uppercase;letter-spacing:.03em}
    .notable{display:flex;gap:1.5rem;flex-wrap:wrap}.notable>div{flex:1;min-width:320px}
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
    th,td{border-color:#3f3f46}.sub,.foot,h3{color:#71717a}}
    """
  end
end
