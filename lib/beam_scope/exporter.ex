defmodule BeamScope.Exporter do
  @moduledoc """
  Behaviour for an **exporter** — a stateless adapter that reads the cluster runtime
  model and emits it to an external observability ecosystem (see `docs/adr/0007`).

  Exporters are leaves of the architecture: they hold no authoritative state and
  never feed back into the model. BeamScope owns the runtime model; Prometheus,
  OpenTelemetry, and LiveDashboard **consume** it.

  MVP exporters (`docs/ROADMAP.md`, Inc 4): Prometheus (via
  `telemetry_metrics_prometheus`) and a dashboard (LiveDashboard page or a minimal
  BeamScope LiveView). OpenTelemetry is "just another exporter" added right after.

  > Not yet implemented — delivered in `docs/ROADMAP.md`, Inc 4.
  """

  @doc """
  Read the given cluster runtime model and emit it downstream.

  Receives (or reads) a consistent view of `BeamScope.ClusterState`. Must be free of
  authoritative side effects on the model.
  """
  @callback export(cluster_state :: term()) :: :ok
end
