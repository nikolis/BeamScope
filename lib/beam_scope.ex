defmodule BeamScope do
  @moduledoc """
  BeamScope — a BEAM-native observability runtime for Elixir/OTP.

  BeamScope maintains a coherent, **distributed runtime model** of an Elixir cluster
  and exports that model to existing observability ecosystems (Prometheus,
  OpenTelemetry, Phoenix LiveDashboard). It is *not* a metrics database, a collector,
  or a Grafana/Prometheus replacement — it **owns the runtime model**; other tools
  consume it.

  ## Pipeline (see `docs/adr/0001`)

      Telemetry → Local Aggregation (ETS) → Runtime Object Model
                → Synchronization → Cluster Runtime Model → Exporters

  The guiding principle is **synchronize observations, not replicate data**:
  high-frequency telemetry is aggregated locally and only compact, versioned
  snapshots cross the network (`docs/adr/0005`).

  ## Public API

  This module is the small, model-oriented public surface (`docs/adr/0009`). It
  exposes rich runtime concepts, never raw counters. All reads are answered from the
  local `BeamScope.ClusterState` replica — local and fast, never a cross-node call.

  The full MVP surface — `cluster/0`, `nodes/0`, `node/1`, `vm/1`, `schedulers/1`,
  `processes/1`, `ets/1`, `mailbox/1` — is implemented as of Inc 3 (`docs/ROADMAP.md`).
  Framework providers add their own accessor as they land (`phoenix/1` for the Phoenix
  HTTP surface), keeping the surface additive (ADR-0009).
  """

  alias BeamScope.{ClusterNode, ClusterState}

  @typedoc "A node in the observed cluster."
  @type node_name :: node()

  @doc "Cluster-wide summary: every known `BeamScope.ClusterNode`."
  @spec cluster() :: [ClusterNode.t()]
  def cluster, do: ClusterState.nodes()

  @doc "All known nodes and their liveness (`:live` / `:stale` / `:expired`)."
  @spec nodes() :: [{node_name(), ClusterNode.liveness()}]
  def nodes do
    ClusterState.nodes() |> Enum.map(&{&1.node, &1.liveness})
  end

  @doc "The full runtime model (`BeamScope.ClusterNode`) for a node, or `nil` if unknown."
  @spec node(node_name()) :: ClusterNode.t() | nil
  def node(the_node), do: ClusterState.get(the_node)

  @doc "VM model (memory, run queue, uptime) for a node, or `nil` if unknown."
  @spec vm(node_name()) :: BeamScope.VM.t() | nil
  def vm(the_node), do: entity(the_node, :vm)

  @doc "Scheduler model (utilization) for a node, or `nil` if unknown."
  @spec schedulers(node_name()) :: BeamScope.Scheduler.t() | nil
  def schedulers(the_node), do: entity(the_node, :scheduler)

  @doc "Process-population summary for a node, or `nil` if unknown."
  @spec processes(node_name()) :: BeamScope.ProcessSummary.t() | nil
  def processes(the_node), do: entity(the_node, :processes)

  @doc "ETS model (table count, memory, largest tables) for a node, or `nil` if unknown."
  @spec ets(node_name()) :: BeamScope.ETS.t() | nil
  def ets(the_node), do: entity(the_node, :ets)

  @doc "Mailbox model (queue totals, distribution, backlog) for a node, or `nil` if unknown."
  @spec mailbox(node_name()) :: BeamScope.Mailbox.t() | nil
  def mailbox(the_node), do: entity(the_node, :mailbox)

  @doc """
  Phoenix HTTP model (windowed request/error rates, latency, status classes) for a node,
  or `nil` if unknown. Requires the opt-in `BeamScope.Provider.Phoenix` provider.
  """
  @spec phoenix(node_name()) :: BeamScope.Phoenix.t() | nil
  def phoenix(the_node), do: entity(the_node, :phoenix)

  # Domains are stored as `domain => [entity]`. The MVP domains are all singletons —
  # return the first (only) entity, if present.
  defp entity(the_node, domain) do
    case ClusterState.get(the_node) do
      %ClusterNode{entities: %{^domain => [entity | _]}} -> entity
      _ -> nil
    end
  end
end
