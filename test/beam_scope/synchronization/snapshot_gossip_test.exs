defmodule BeamScope.Synchronization.SnapshotGossipTest do
  use ExUnit.Case, async: false

  alias BeamScope.{ClusterNode, ClusterState, VM}
  alias BeamScope.Synchronization.SnapshotGossip

  @topic "beam_scope:snapshots"

  setup do
    start_supervised!({Phoenix.PubSub, name: BeamScope.PubSub})

    prev = Application.get_all_env(:beam_scope)
    Application.put_env(:beam_scope, :pubsub, BeamScope.PubSub)
    Application.put_env(:beam_scope, :node_ttl, 200)

    on_exit(fn ->
      Application.put_env(:beam_scope, :pubsub, prev[:pubsub])
      Application.put_env(:beam_scope, :node_ttl, prev[:node_ttl])
    end)

    :ets.delete_all_objects(:beam_scope_cluster_state)
    :ok
  end

  test "publish/1 broadcasts the local snapshot to topic subscribers" do
    Phoenix.PubSub.subscribe(BeamScope.PubSub, @topic)
    snapshot = %ClusterNode{node: Kernel.node(), version: 3, entities: %{vm: [%VM{run_queue: 2}]}}

    assert SnapshotGossip.publish(snapshot) == :ok
    assert_receive {:beam_scope_snapshot, ^snapshot}
  end

  test "publish/1 is a no-op when there is no local snapshot yet" do
    assert SnapshotGossip.publish(nil) == :ok
  end

  test "an inbound peer snapshot is merged; our own broadcast is ignored" do
    pid = start_supervised!(SnapshotGossip)

    remote = %ClusterNode{
      node: :peer@host,
      incarnation: 1,
      version: 7,
      observed_at: System.system_time(:millisecond),
      entities: %{vm: [%VM{run_queue: 4}]}
    }

    send(pid, {:beam_scope_snapshot, remote})
    send(pid, {:beam_scope_snapshot, %ClusterNode{node: Kernel.node(), version: 99}})
    :sys.get_state(pid)

    assert %ClusterNode{version: 7, liveness: :live} = ClusterState.get(:peer@host)
    # our own inbound snapshot did not create/overwrite a local entry
    assert ClusterState.get(Kernel.node()) == nil
  end

  test ":nodedown expires the peer promptly" do
    pid = start_supervised!(SnapshotGossip)

    ClusterState.merge(%ClusterNode{
      node: :peer@host,
      incarnation: 1,
      version: 1,
      observed_at: System.system_time(:millisecond),
      entities: %{}
    })

    send(pid, {:nodedown, :peer@host})
    :sys.get_state(pid)

    assert ClusterState.get(:peer@host).liveness == :expired
  end

  test "the sweep timer ages a stale peer to :expired" do
    ClusterState.merge(%ClusterNode{
      node: :peer@host,
      incarnation: 1,
      version: 1,
      # already older than 2 * node_ttl (200ms) so the first sweep expires it
      observed_at: System.system_time(:millisecond) - 1_000,
      entities: %{}
    })

    start_supervised!(SnapshotGossip)

    assert eventually(fn ->
             match?(%ClusterNode{liveness: :expired}, ClusterState.get(:peer@host))
           end)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: flunk("condition not met within timeout")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
