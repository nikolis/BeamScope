# Snapshot size & gossip cost vs. cluster size (ADR-0003/0005).
#
#     mix run bench/snapshot_size.exs
#
# The default snapshot-gossip strategy sends one compact snapshot per node per tick, so
# network cost scales with cluster size, NOT telemetry frequency. This quantifies the
# per-node snapshot size and the O(N^2) full-mesh delivery count, which is the known
# scaling limit called out in ADR-0005.

alias BeamScope.{ClusterNode, ETS, ProcessSummary, Scheduler, VM}
alias BeamScope.Exporter.Prometheus

entries = fn n -> for i <- 1..n, do: %{pid: "#PID<0.#{i}.0>", name: :some_proc, value: i * 1000} end
ets_entries = fn n -> for i <- 1..n, do: %{name: :"table_#{i}", memory_bytes: i * 1000, size: i} end

full_node = fn i ->
  %ClusterNode{
    node: :"node#{i}@host.example.com",
    incarnation: 1,
    version: i,
    observed_at: System.system_time(:millisecond),
    liveness: :live,
    entities: %{
      vm: [
        %VM{
          memory: %{total: 100_000_000, processes: 40_000_000, binary: 5_000_000, ets: 2_000_000, atom: 1_000_000},
          run_queue: 3,
          uptime_ms: 123_456,
          otp_release: "28"
        }
      ],
      scheduler: [
        %Scheduler{
          count: 16,
          online: 16,
          dirty_cpu: 16,
          dirty_io: 10,
          utilization: 0.1234,
          per_scheduler: for(s <- 1..16, do: %{id: s, utilization: 0.1})
        }
      ],
      processes: [%ProcessSummary{count: 50_000, limit: 1_048_576, top_mailboxes: entries.(5), top_memory: entries.(5)}],
      ets: [%ETS{table_count: 120, memory_bytes: 30_000_000, largest: ets_entries.(5)}]
    }
  }
end

per_node_bytes = byte_size(:erlang.term_to_binary(full_node.(1), [:compressed]))

IO.puts("\nPer-node snapshot (term_to_binary, compressed): #{per_node_bytes} bytes\n")

IO.puts(
  String.pad_trailing("nodes", 8) <>
    String.pad_trailing("state (KB)", 14) <>
    String.pad_trailing("scrape (KB)", 14) <>
    String.pad_trailing("msgs/tick", 12) <> "deliveries/tick"
)

IO.puts(String.duplicate("-", 62))

for n <- [1, 5, 10, 25, 50, 100, 250] do
  nodes = Enum.map(1..n, full_node)
  state_kb = Float.round(n * per_node_bytes / 1024, 1)
  scrape_kb = Float.round(byte_size(IO.iodata_to_binary(Prometheus.render(nodes))) / 1024, 1)
  # full-mesh gossip: each node broadcasts once per tick (n msgs), delivered to n-1 peers.
  deliveries = n * (n - 1)

  IO.puts(
    String.pad_trailing(Integer.to_string(n), 8) <>
      String.pad_trailing(Float.to_string(state_kb), 14) <>
      String.pad_trailing(Float.to_string(scrape_kb), 14) <>
      String.pad_trailing(Integer.to_string(n), 12) <>
      Integer.to_string(deliveries)
  )
end

IO.puts("""

Reading: per-node state is tiny and O(N); the scrape is O(N). The scaling limit is
`deliveries/tick = N*(N-1)` (full-mesh gossip), which is why ADR-0005 keeps synchronization
pluggable — a partial-gossip / tree / sidecar strategy replaces only that layer.
""")
