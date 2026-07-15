# Only compiled when Plug is available (an optional dependency). A host without Plug can
# still use the dependency-free render functions in BeamScope.Exporter.{Prometheus,Dashboard}.
if Code.ensure_loaded?(Plug.Router) do
  defmodule BeamScope.Exporter.Router do
    @moduledoc """
    Plug router exposing the BeamScope exporters (ADR-0007):

      * `GET /metrics` — Prometheus text exposition of the cluster model.
      * `GET /` — the HTML dashboard.

    Mount it in a host Plug/Phoenix stack, or let `BeamScope.Exporters.Supervisor` serve it
    on a standalone Bandit endpoint.
    """

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/metrics" do
      conn
      |> put_resp_content_type("text/plain; version=0.0.4")
      |> send_resp(200, BeamScope.Exporter.Prometheus.scrape())
    end

    get "/" do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, BeamScope.Exporter.Dashboard.page())
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end
end
