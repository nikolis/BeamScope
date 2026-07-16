defmodule BeamScope.Integration.ClusterSyncTest do
  @moduledoc """
  End-to-end MVP acceptance test (ADR-0005, docs/ROADMAP.md) on a real 2-node cluster: a
  VM metric produced on a peer node becomes visible locally through `BeamScope.vm/1` and
  the Prometheus scrape, and the peer's liveness degrades gracefully when it leaves.

  Opt-in (spins up a peer via `:peer` + distribution): `mix test --only distributed`.
  """
  use ExUnit.Case, async: false
  @moduletag :distributed

  alias BeamScope.VM
  alias BeamScope.Exporter.Prometheus

  @cookie :beam_scope_integration

  setup_all do
    case :net_kernel.start([:"primary@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Node.set_cookie(@cookie)
    :ok
  end

  test "a peer's VM is visible locally + in the scrape, and expires when it leaves" do
    start_local_pipeline()
    remote = start_peer()
    on_exit(fn -> stop(remote) end)

    local = Node.self()

    # Cross-node visibility both directions.
    assert eventually(fn -> has_vm?(BeamScope.vm(remote)) end)
    assert eventually(fn -> has_vm?(:erpc.call(remote, BeamScope, :vm, [local])) end)

    # Any node's Prometheus scrape covers the whole cluster.
    scrape = Prometheus.scrape()
    assert scrape =~ ~s(node="#{local}")
    assert scrape =~ ~s(node="#{remote}")

    # Graceful degradation when the peer leaves.
    stop(remote)
    assert eventually(fn -> BeamScope.node(remote).liveness in [:stale, :expired] end, 80)
  end

  # --- helpers ---

  defp start_local_pipeline do
    Application.put_env(:beam_scope, :pubsub, BeamScope.PubSub)
    Application.put_env(:beam_scope, :sync_interval, 100)
    Application.put_env(:beam_scope, :node_ttl, 800)

    :ets.delete_all_objects(:beam_scope_cluster_state)
    start_supervised!({Phoenix.PubSub, name: BeamScope.PubSub})
    start_supervised!(BeamScope.Aggregation.Supervisor)
    start_supervised!(BeamScope.Synchronization.SnapshotGossip)
    :ok
  end

  defp start_peer do
    {:ok, _pid, node} =
      :peer.start(%{
        name: :beam_scope_peer,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(@cookie)]
      })

    true = wait_connected(node)

    # Drive the peer over distribution (:erpc): share code paths, configure, boot BeamScope.
    :erpc.call(node, :code, :add_paths, [:code.get_path()])

    for {key, value} <- peer_env(),
        do: :erpc.call(node, Application, :put_env, [:beam_scope, key, value])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:beam_scope])

    node
  end

  defp peer_env do
    [
      pubsub: BeamScope.PubSub,
      start_pubsub: true,
      sync: BeamScope.Synchronization.SnapshotGossip,
      sync_interval: 100,
      node_ttl: 800,
      top_n: 5
    ]
  end

  defp stop(node) do
    :erpc.cast(node, :init, :stop, [])
  catch
    _, _ -> :ok
  end

  defp has_vm?(%VM{memory: %{total: total}}) when is_integer(total), do: true
  defp has_vm?(_), do: false

  defp wait_connected(node, tries \\ 60)
  defp wait_connected(_node, 0), do: false

  defp wait_connected(node, tries) do
    if node in Node.list() and Node.ping(node) == :pong do
      true
    else
      Process.sleep(50)
      wait_connected(node, tries - 1)
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
