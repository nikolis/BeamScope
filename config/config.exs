import Config

# BeamScope is embedded into a host application (docs/adr/0002). It references
# host-provided infrastructure by name rather than owning it.
#
# The default synchronization strategy (docs/adr/0005) gossips snapshots over the
# host's Phoenix.PubSub server. Point BeamScope at that server here:
#
#     config :beam_scope,
#       pubsub: MyApp.PubSub,
#       sync: BeamScope.Synchronization.SnapshotGossip,
#       sync_interval: :timer.seconds(1),
#       node_ttl: :timer.seconds(5)
#
# Domain providers and exporters follow the `enabled?/0` convention and are
# feature-toggled per environment (docs/adr/0007, docs/adr/0008).

config :beam_scope,
  sync: BeamScope.Synchronization.SnapshotGossip,
  sync_interval: :timer.seconds(1),
  node_ttl: :timer.seconds(5),
  # Top-N bound for the Process/ETS providers (largest mailboxes/memory/tables).
  top_n: 5

# Enabled domain providers (ADR-0008). Defaults to VM + Scheduler + Processes + ETS;
# override to add framework providers or drop heavier ones (e.g. to avoid enabling the
# global :scheduler_wall_time flag). Shape: [{provider_module, domain_atom}, ...].
#
#     config :beam_scope, providers: [{BeamScope.Provider.VM, :vm}]

import_config "#{config_env()}.exs"
