defmodule BeamScope.Application do
  @moduledoc """
  OTP application for BeamScope (embedded mode — see `docs/adr/0002`).

  BeamScope runs *inside* each node of a host BEAM cluster. Every node owns a full
  replica of the cluster runtime model; there is no central aggregator.

  Foundational supervision tree (children are added per the roadmap in
  `docs/ROADMAP.md`; this skeleton starts empty so the project compiles without
  claiming to work):

      BeamScope.Supervisor  (:one_for_one)
      ├── BeamScope.ClusterState           # per-node replica of the runtime model
      ├── BeamScope.Aggregation.Supervisor # per-DomainProvider local aggregators
      ├── BeamScope.Synchronization         # configured sync strategy (default: snapshot gossip)
      └── BeamScope.Exporters.Supervisor    # stateless exporter adapters (feature-toggled)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Owns the per-node replica of the cluster model; must start first — everything
        # else reads from or writes to it.
        BeamScope.ClusterState
      ] ++
        pubsub_children() ++
        aggregation_children() ++
        sync_children() ++
        [BeamScope.Exporters.Supervisor]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamScope.Supervisor)
  end

  # Embedded mode: the host provides Phoenix.PubSub. For standalone/dev runs we start our
  # own so the default gossip strategy has a transport (config :beam_scope, start_pubsub: true).
  defp pubsub_children do
    with true <- Application.get_env(:beam_scope, :start_pubsub, false),
         name when not is_nil(name) <- Application.get_env(:beam_scope, :pubsub) do
      [{Phoenix.PubSub, name: name}]
    else
      _ -> []
    end
  end

  # Local aggregation is toggleable so tests can drive `ClusterState` deterministically
  # (see config/test.exs).
  defp aggregation_children do
    if Application.get_env(:beam_scope, :aggregation, true) do
      [BeamScope.Aggregation.Supervisor]
    else
      []
    end
  end

  # Synchronization starts only when a strategy module and a PubSub server are both
  # configured, so an embedded host that hasn't wired PubSub yet stays inert.
  defp sync_children do
    with mod when is_atom(mod) and mod not in [nil, false] <-
           Application.get_env(:beam_scope, :sync),
         name when not is_nil(name) <- Application.get_env(:beam_scope, :pubsub) do
      [mod]
    else
      _ -> []
    end
  end
end
