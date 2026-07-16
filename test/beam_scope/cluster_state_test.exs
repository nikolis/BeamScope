defmodule BeamScope.ClusterStateTest do
  use ExUnit.Case, async: false

  alias BeamScope.{ClusterNode, ClusterState, VM}

  setup do
    # ClusterState is started by the application; reset its table between tests.
    ClusterState.reset()
    :ok
  end

  describe "put_local/1" do
    test "stores entities under the local node with a monotonic version" do
      %ClusterNode{version: v1} = ClusterState.put_local(%{vm: [%VM{run_queue: 1}]})
      %ClusterNode{version: v2} = ClusterState.put_local(%{vm: [%VM{run_queue: 2}]})

      assert v2 > v1

      cn = ClusterState.get(Kernel.node())
      assert cn.node == Kernel.node()
      assert cn.liveness == :live
      assert [%VM{run_queue: 2}] = cn.entities.vm
    end

    test "merges new domains without dropping existing ones" do
      ClusterState.put_local(%{vm: [%VM{run_queue: 7}]})
      ClusterState.put_local(%{other: [:placeholder]})

      cn = ClusterState.get(Kernel.node())
      assert [%VM{run_queue: 7}] = cn.entities.vm
      assert cn.entities.other == [:placeholder]
    end
  end

  describe "get/1 and nodes/0" do
    test "get/1 returns nil for an unknown node" do
      assert ClusterState.get(:nobody@nowhere) == nil
    end

    test "nodes/0 lists every known ClusterNode" do
      ClusterState.put_local(%{vm: [%VM{}]})
      ClusterState.merge(remote(:b@host, 1))

      names = ClusterState.nodes() |> Enum.map(& &1.node) |> Enum.sort()
      assert names == Enum.sort([Kernel.node(), :b@host])
    end
  end

  describe "merge/1 (last-observation-wins per node, by version)" do
    test "applies a newer snapshot and ignores an older one" do
      assert ClusterState.merge(remote(:b@host, 5)) == :merged
      assert ClusterState.merge(remote(:b@host, 4)) == :ignored
      assert ClusterState.merge(remote(:b@host, 6)) == :merged

      assert ClusterState.get(:b@host).version == 6
    end
  end

  describe "merge/1 restart handling (incarnation dominates version)" do
    test "a newer incarnation revives a node even when its version resets" do
      now = System.system_time(:millisecond)
      pre = %ClusterNode{node: :b@host, incarnation: 100, version: 50, observed_at: now}
      restarted = %ClusterNode{node: :b@host, incarnation: 200, version: 1, observed_at: now}
      stale = %ClusterNode{node: :b@host, incarnation: 100, version: 999, observed_at: now}

      assert ClusterState.merge(pre) == :merged
      assert ClusterState.merge(restarted) == :merged
      assert ClusterState.get(:b@host).incarnation == 200
      # an older incarnation loses regardless of its version
      assert ClusterState.merge(stale) == :ignored
      assert ClusterState.get(:b@host).version == 1
    end
  end

  describe "expire_node/1" do
    test "marks a remote node :expired but never the local node" do
      ClusterState.merge(remote(:b@host, 1))
      ClusterState.expire_node(:b@host)
      assert ClusterState.get(:b@host).liveness == :expired

      ClusterState.put_local(%{vm: [%VM{}]})
      ClusterState.expire_node(Kernel.node())
      assert ClusterState.get(Kernel.node()).liveness == :live
    end
  end

  describe "expire/2" do
    test "ages a remote node :live -> :stale -> :expired by receipt age" do
      ttl = 1_000

      ClusterState.merge(remote(:b@host, 1))
      %ClusterNode{received_at: received} = ClusterState.get(:b@host)

      ClusterState.expire(received + 500, ttl)
      assert ClusterState.get(:b@host).liveness == :live

      ClusterState.expire(received + 1_500, ttl)
      assert ClusterState.get(:b@host).liveness == :stale

      ClusterState.expire(received + 3_000, ttl)
      assert ClusterState.get(:b@host).liveness == :expired
    end

    test "ignores the sender's wall clock: skewed observed_at cannot affect expiry" do
      ttl = 1_000
      now = System.system_time(:millisecond)

      # Sender clocks skewed a minute ahead/behind — expiry must age on the local
      # receipt time regardless (ADR-0005: observed_at is display metadata only).
      ClusterState.merge(%{remote(:ahead@host, 1) | observed_at: now + 60_000})
      ClusterState.merge(%{remote(:behind@host, 1) | observed_at: now - 60_000})
      %ClusterNode{received_at: received} = ClusterState.get(:ahead@host)

      ClusterState.expire(received + 500, ttl)
      assert ClusterState.get(:ahead@host).liveness == :live
      assert ClusterState.get(:behind@host).liveness == :live

      ClusterState.expire(received + 3_000, ttl)
      assert ClusterState.get(:ahead@host).liveness == :expired
      assert ClusterState.get(:behind@host).liveness == :expired
    end

    test "never expires the local node" do
      ClusterState.put_local(%{vm: [%VM{}]})
      ClusterState.expire(System.system_time(:millisecond) + 10_000, 1)

      assert ClusterState.get(Kernel.node()).liveness == :live
    end
  end

  defp remote(name, version) do
    %ClusterNode{
      node: name,
      version: version,
      observed_at: System.system_time(:millisecond),
      entities: %{vm: [%VM{}]}
    }
  end
end
