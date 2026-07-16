defmodule BeamScope.Exporter do
  @moduledoc """
  Behaviour for an **exporter** — a stateless adapter that reads the cluster runtime
  model and emits it to an external observability ecosystem (see `docs/adr/0007`).

  Exporters are leaves of the architecture: they hold no authoritative state and
  never feed back into the model. BeamScope owns the runtime model; Prometheus,
  OpenTelemetry, and LiveDashboard **consume** it.

  The MVP exporters (`docs/ROADMAP.md`, Inc 4) are **pull**-based, so they use the
  `render`/`Plug` seam instead of `export/1`: `BeamScope.Exporter.Prometheus` renders
  the model to text exposition at scrape time and `BeamScope.Exporter.Dashboard`
  renders a self-contained HTML page, both served by `BeamScope.Exporter.Router`.

  `export/1` is the seam for **push**-based exporters (e.g. the post-MVP
  OpenTelemetry exporter) that periodically emit the model downstream; it has no
  implementations yet.
  """

  @doc """
  Read the given cluster runtime model and emit it downstream.

  Receives (or reads) a consistent view of `BeamScope.ClusterState`. Must be free of
  authoritative side effects on the model.
  """
  @callback export(cluster_state :: term()) :: :ok
end
