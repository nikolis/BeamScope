defmodule BeamScope.Exporter.DashboardTest do
  use ExUnit.Case, async: true

  alias BeamScope.{ClusterNode, ProcessSummary, VM}
  alias BeamScope.Exporter.Dashboard

  test "render/1 builds an HTML page with a row per node" do
    nodes = [
      %ClusterNode{
        node: :a@h,
        liveness: :live,
        entities: %{
          vm: [%VM{memory: %{total: 2_097_152}, run_queue: 1, uptime_ms: 5_000}],
          processes: [%ProcessSummary{count: 10, limit: 100}]
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
    # a node without a VM entity renders an em dash rather than crashing
    assert html =~ "—"
  end

  test "render/1 escapes HTML in values" do
    node = %ClusterNode{node: :a@h, liveness: :live, entities: %{}}
    html = Dashboard.render([node]) |> IO.iodata_to_binary()
    refute html =~ "<script>"
  end
end
