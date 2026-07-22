defmodule BeamScope.Exporter.PrometheusTest do
  use ExUnit.Case, async: false

  alias BeamScope.{
    ClusterNode,
    ClusterState,
    ETS,
    Mailbox,
    Phoenix,
    ProcessSummary,
    Scheduler,
    VM
  }

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
        ets: [%ETS{table_count: 4, memory_bytes: 2_048}],
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
            requests: 128,
            errors: 3,
            error_rate: 0.0234375,
            avg_latency_ms: 12.5,
            latency_distribution: %{
              "0-10" => 100,
              "10-50" => 20,
              "50-200" => 5,
              "200-1000" => 2,
              "1000+" => 1
            },
            status_classes: %{"2xx" => 120, "3xx" => 0, "4xx" => 5, "5xx" => 3},
            window_ms: 1000,
            requests_total: 10_000,
            errors_total: 42,
            top_slow: [
              %BeamScope.Phoenix.NotableRequest{
                route: "/users/:id",
                status: 200,
                latency_ms: 950,
                at: 1_000
              }
            ],
            recent_5xx: [
              %BeamScope.Phoenix.NotableRequest{
                route: "/checkout",
                status: 503,
                latency_ms: 40,
                at: 1_000
              }
            ]
          }
        ]
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
    assert text =~ "# TYPE beamscope_mailbox_total_queued gauge"
    assert text =~ ~s(beamscope_mailbox_total_queued{node="a@h"} 42)
    assert text =~ ~s(beamscope_mailbox_backlogged{node="a@h",threshold="1000"} 2)
    assert text =~ ~s(beamscope_mailbox_distribution{node="a@h",bucket="1000+"} 1)
    assert text =~ "# TYPE beamscope_phoenix_requests gauge"
    assert text =~ ~s(beamscope_phoenix_requests{node="a@h"} 128)
    assert text =~ ~s(beamscope_phoenix_requests_total{node="a@h"} 10000)
    assert text =~ ~s(beamscope_phoenix_errors_total{node="a@h"} 42)
    assert text =~ ~s(beamscope_phoenix_avg_latency_ms{node="a@h"} 12.5)
    assert text =~ ~s(beamscope_phoenix_status{node="a@h",class="2xx"} 120)
    assert text =~ ~s(beamscope_phoenix_latency{node="a@h",bucket="0-10"} 100)
  end

  test "render/1 never emits a per-route family or leaks route templates (ADR-0010)" do
    text = Prometheus.render([full_node(:a@h)]) |> IO.iodata_to_binary()

    # notable requests are a dashboard/API surface only — no unbounded-cardinality route labels
    refute text =~ "beamscope_phoenix_route"
    refute text =~ ~s(route=)
    refute text =~ "/users/:id"
    refute text =~ "/checkout"
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
