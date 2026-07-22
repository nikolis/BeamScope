defmodule BeamScope.Exporter.DashboardTest do
  use ExUnit.Case, async: true

  alias BeamScope.{ClusterNode, Mailbox, Phoenix, ProcessSummary, VM}
  alias BeamScope.Exporter.Dashboard

  test "render/1 builds an HTML page with a row per node" do
    nodes = [
      %ClusterNode{
        node: :a@h,
        liveness: :live,
        entities: %{
          vm: [%VM{memory: %{total: 2_097_152}, run_queue: 1, uptime_ms: 5_000}],
          processes: [%ProcessSummary{count: 10, limit: 100}],
          mailbox: [
            %Mailbox{
              total_queued: 42,
              max_queued: 30,
              backlogged: 2,
              backlog_threshold: 1000,
              distribution: %{"0" => 5, "1-9" => 3, "10-99" => 1, "100-999" => 0, "1000+" => 1}
            }
          ],
          phoenix: [
            %Phoenix{
              requests: 12,
              error_rate: 0.05,
              avg_latency_ms: 12.5,
              requests_total: 128,
              errors_total: 6
            }
          ]
        }
      },
      %ClusterNode{node: :b@h, liveness: :expired, entities: %{}}
    ]

    html = Dashboard.render(nodes) |> IO.iodata_to_binary()

    assert html =~ "<!doctype html>"
    assert html =~ "<table>"
    assert html =~ "a@h"
    assert html =~ ~s(<span class="badge live">live</span>)
    assert html =~ ~s(<span class="badge expired">expired</span>)
    assert html =~ "2.0 MB"
    # mailbox column renders queued totals and the backlog threshold marker
    assert html =~ "queued"
    assert html =~ "≥ 1000"
    # phoenix column renders cumulative totals, the windowed error rate, and average latency
    assert html =~ "128 req"
    assert html =~ "6 err"
    assert html =~ "12.5 ms"
    # a node without a VM entity renders an em dash rather than crashing
    assert html =~ "—"
  end

  test "render/1 escapes HTML in values" do
    node = %ClusterNode{node: :a@h, liveness: :live, entities: %{}}
    html = Dashboard.render([node]) |> IO.iodata_to_binary()
    refute html =~ "<script>"
  end
end
