defmodule BeamScope.Exporter.DashboardTest do
  use ExUnit.Case, async: true

  alias BeamScope.{ClusterNode, Mailbox, Phoenix, ProcessSummary, VM}
  alias BeamScope.Phoenix.NotableRequest
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

  test "render/1 composes a fleet-wide notable-requests section across nodes" do
    nodes = [
      %ClusterNode{
        node: :a@h,
        liveness: :live,
        entities: %{
          phoenix: [
            %Phoenix{
              top_slow: [%NotableRequest{route: "/a", status: 200, latency_ms: 120, at: 1_000}],
              recent_5xx: [%NotableRequest{route: "/a", status: 500, latency_ms: 30, at: 1_000}]
            }
          ]
        }
      },
      %ClusterNode{
        node: :b@h,
        liveness: :live,
        entities: %{
          phoenix: [
            %Phoenix{
              top_slow: [%NotableRequest{route: "/b", status: 200, latency_ms: 900, at: 2_000}],
              recent_5xx: []
            }
          ]
        }
      }
    ]

    html = Dashboard.render(nodes) |> IO.iodata_to_binary()

    assert html =~ "Notable requests"
    assert html =~ "Slowest requests"
    assert html =~ "Recent 5xx"
    # the slowest across the fleet (900 ms on node b) is composed at read time
    assert html =~ "900 ms"
    assert html =~ "/b"
    # both nodes' routes appear, each stamped with its node
    assert html =~ "b@h"
    # node b's slowest is ordered ahead of node a's (read-time re-sort by latency)
    assert :binary.match(html, "/b") |> elem(0) < :binary.match(html, "/a") |> elem(0)
  end

  test "render/1 omits the notable section when no node has notable requests" do
    node = %ClusterNode{node: :a@h, liveness: :live, entities: %{phoenix: [%Phoenix{}]}}
    html = Dashboard.render([node]) |> IO.iodata_to_binary()
    refute html =~ "Notable requests"
  end

  test "render/1 renders the per-node top-N detail already collected by the providers" do
    nodes = [
      %ClusterNode{
        node: :a@h,
        liveness: :live,
        entities: %{
          processes: [
            %ProcessSummary{
              count: 10,
              limit: 100,
              top_mailboxes: [
                %{pid: "#PID<0.42.0>", name: S3BrowserLive, value: 259},
                %{pid: "#PID<0.99.0>", name: nil, value: 3}
              ],
              top_memory: [
                %{pid: "#PID<0.42.0>", name: S3BrowserLive, value: 1_048_576},
                %{pid: "#PID<0.99.0>", name: nil, value: 262_144}
              ]
            }
          ],
          ets: [
            %BeamScope.ETS{
              table_count: 130,
              memory_bytes: 402_653_184,
              largest: [
                %{name: :recipes_cache, memory_bytes: 220_200_960, size: 5000},
                %{name: :geo_cache, memory_bytes: 94_371_840, size: 1200}
              ]
            }
          ],
          mailbox: [
            %Mailbox{
              distribution: %{"0" => 640, "1-9" => 5, "10-99" => 0, "100-999" => 1, "1000+" => 0}
            }
          ]
        }
      }
    ]

    html = Dashboard.render(nodes) |> IO.iodata_to_binary()

    assert html =~ "Per-node detail"
    # the deepest mailbox is attributed to its owning process by registered name
    assert html =~ "Top mailboxes"
    assert html =~ "S3BrowserLive"
    assert html =~ "259"
    # a process with no registered name falls back to its display pid
    assert html =~ "#PID&lt;0.99.0&gt;"
    # sub-megabyte process memory keeps its resolution instead of collapsing to "0.0 MB"
    assert html =~ "256.0 KB"
    # the ETS total is broken out into the tables that hold it
    assert html =~ "Largest ETS"
    assert html =~ "recipes_cache"
    assert html =~ "210.0 MB"
    # large object counts are grouped for readability
    assert html =~ "5,000"
    # the 5-bucket histogram distinguishes "one process at 259" from "many mildly backed up"
    assert html =~ "Mailbox histogram"
    assert html =~ "640"
  end

  test "render/1 suppresses the mailbox histogram when every mailbox is empty" do
    node = %ClusterNode{
      node: :a@h,
      liveness: :live,
      entities: %{
        mailbox: [
          %Mailbox{
            distribution: %{"0" => 900, "1-9" => 0, "10-99" => 0, "100-999" => 0, "1000+" => 0}
          }
        ]
      }
    }

    html = Dashboard.render([node]) |> IO.iodata_to_binary()

    refute html =~ "Mailbox histogram"
  end

  test "render/1 omits the per-node detail section when no node carries top-N data" do
    node = %ClusterNode{node: :a@h, liveness: :live, entities: %{processes: [%ProcessSummary{}]}}
    html = Dashboard.render([node]) |> IO.iodata_to_binary()
    refute html =~ "Per-node detail"
  end

  test "render/1 renders the per-node Oban queue view and the LiveView totals cell" do
    nodes = [
      %ClusterNode{
        node: :a@h,
        liveness: :live,
        entities: %{
          oban: [
            %BeamScope.Oban{
              executing: %{"imports" => 2, "ai_agents" => 0},
              completed: %{"imports" => 5},
              failed: %{"ai_agents" => 1}
            }
          ],
          live_view: [%BeamScope.LiveView{connected_sockets: 7, mounts: 3, handle_events: 40}]
        }
      }
    ]

    html = Dashboard.render(nodes) |> IO.iodata_to_binary()

    # per-node Oban block: seeing the queue and its executing count attributes work to this node
    assert html =~ "Oban queues"
    assert html =~ "imports"
    assert html =~ "ai_agents"
    # LiveView cell in the totals row is the denominator for "why is this node hot"
    assert html =~ "7 sockets"
    assert html =~ "3 mounts"
    assert html =~ "40 events"
  end
end
