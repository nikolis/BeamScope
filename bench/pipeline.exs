# Micro-benchmarks for the hot paths of the BeamScope pipeline (ADR-0003/0006/0007).
#
#     mix run bench/pipeline.exs
#
# Measures the operations that run per tick / per scrape, so their cost is understood
# before it matters at scale.

alias BeamScope.{ClusterNode, ClusterState, VM}
alias BeamScope.Exporter.Prometheus
alias BeamScope.Provider

# A representative local accumulator for the VM provider.
vm_acc = :ets.new(:bench_vm_acc, [:public, :set])
Provider.VM.aggregate([:vm, :memory], Map.new(:erlang.memory()), %{}, vm_acc)
Provider.VM.aggregate([:vm, :run_queue], %{total: 3}, %{}, vm_acc)

remote_snapshot = fn i ->
  %ClusterNode{
    node: :"node#{i}@host",
    incarnation: 1,
    version: i,
    observed_at: System.system_time(:millisecond),
    entities: %{vm: [%VM{memory: %{total: 1_000 + i}, run_queue: 0, uptime_ms: i}]}
  }
end

Benchee.run(
  %{
    "VM provider snapshot/1 (per tick)" => fn -> Provider.VM.snapshot(vm_acc) end,
    "ClusterState.put_local/1 (per tick)" => fn ->
      ClusterState.put_local(%{vm: [%VM{memory: %{total: 1}, run_queue: 0}]})
    end,
    "ClusterState.merge/1 (per inbound snapshot)" => fn ->
      ClusterState.merge(remote_snapshot.(:rand.uniform(1_000)))
    end
  },
  time: 3,
  memory_time: 1,
  print: [configuration: false]
)
