defmodule BeamScope.Exporter.PrometheusTest do
  use ExUnit.Case, async: false

  alias BeamScope.{ClusterNode, ClusterState, ETS, ProcessSummary, Scheduler, VM}
  alias BeamScope.Exporter.Prometheus

  defp full_node(name, liveness \\ :live, util \\ 0.5) do
    %ClusterNode{
      node: name,
      liveness: liveness,
      entities: %{
        vm: [
          %VM{
            memory: %{total: 100, processes: 40, binary: nil, ets: 3, atom: 2},
            run_queue: 5,
            uptime_ms: 1_000,
            otp_release: "28"
          }
        ],
        scheduler: [%Scheduler{count: 8, online: 8, utilization: util}],
        processes: [%ProcessSummary{count: 10, limit: 100}],
        ets: [%ETS{table_count: 4, memory_bytes: 2_048}]
      }
    }
  end

  test "render/1 produces valid, node-labelled Prometheus text" do
    text = Prometheus.render([full_node(:a@h)]) |> IO.iodata_to_binary()

    assert text =~ "# TYPE beamscope_node_up gauge"
    assert text =~ ~s(beamscope_node_up{node="a@h"} 1)
    assert text =~ ~s(beamscope_vm_memory_bytes{node="a@h",kind="total"} 100)
    assert text =~ ~s(beamscope_vm_run_queue{node="a@h"} 5)
    assert text =~ ~s(beamscope_scheduler_utilization{node="a@h"} 0.5)
    assert text =~ ~s(beamscope_process_count{node="a@h"} 10)
    assert text =~ ~s(beamscope_ets_memory_bytes{node="a@h"} 2048)
  end

  test "render/1 skips nil measurements (no binary memory series)" do
    text = Prometheus.render([full_node(:a@h)]) |> IO.iodata_to_binary()
    refute text =~ ~s(kind="binary")
  end

  test "render/1 marks non-live nodes down and omits nil utilization" do
    text = Prometheus.render([full_node(:b@h, :expired, nil)]) |> IO.iodata_to_binary()

    assert text =~ ~s(beamscope_node_up{node="b@h"} 0)
    # utilization was nil -> no series for that node
    refute text =~ ~s(beamscope_scheduler_utilization{node="b@h"})
  end

  test "scrape/0 renders the live ClusterState" do
    ClusterState.reset()
    ClusterState.put_local(%{vm: [%VM{memory: %{total: 123}, run_queue: 0}]})

    text = Prometheus.scrape()
    node = Kernel.node() |> to_string()
    assert text =~ "beamscope_vm_memory_bytes{node=\"#{node}\",kind=\"total\"} 123"
  end
end
