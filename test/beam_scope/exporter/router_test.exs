defmodule BeamScope.Exporter.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias BeamScope.{ClusterState, VM}
  alias BeamScope.Exporter.Router

  @opts Router.init([])

  setup do
    ClusterState.reset()
    ClusterState.put_local(%{vm: [%VM{memory: %{total: 42}, run_queue: 0}]})
    :ok
  end

  test "GET /metrics returns Prometheus text" do
    conn = Router.call(conn(:get, "/metrics"), @opts)

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain; version=0.0.4"
    assert conn.resp_body =~ "beamscope_vm_memory_bytes"
  end

  test "GET / returns the HTML dashboard" do
    conn = Router.call(conn(:get, "/"), @opts)

    assert conn.status == 200
    assert ["text/html; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert conn.resp_body =~ "<table>"
  end

  test "unknown paths 404" do
    conn = Router.call(conn(:get, "/nope"), @opts)
    assert conn.status == 404
  end
end
