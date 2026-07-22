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
# Domain providers and exporters are feature-toggled per environment via config:
# providers through the `:providers` list (docs/adr/0008), the exporter endpoint
# through the presence of `exporter: [port: ...]` (docs/adr/0007).

config :beam_scope,
  sync: BeamScope.Synchronization.SnapshotGossip,
  sync_interval: :timer.seconds(1),
  node_ttl: :timer.seconds(5),
  # Top-N bound for the Process/ETS providers (largest mailboxes/memory/tables) and for the
  # Phoenix provider's bounded notable-request samples (top_slow/recent_5xx, ADR-0010).
  top_n: 5,
  # Latency floor (ms) for the Phoenix `top_slow` sample: only requests at least this slow are
  # sampled (and pay route-template extraction), so the fast majority costs nothing extra.
  phoenix_slow_floor_ms: 50,
  # Backlog threshold for the Mailbox provider: processes with a mailbox this long or
  # longer are counted as backlogged.
  mailbox_backlog_threshold: 1000

# Framework domain providers (ADR-0008). The core defaults — VM + Scheduler + Processes +
# ETS + Mailbox — are always enabled; the `:providers` list is *merged on top* of them, so
# it adds providers rather than replacing the set. Shape: [{provider_module, domain_atom}, ...].
# To observe a Phoenix host's HTTP surface, just add its provider — the defaults keep running:
#
#     config :beam_scope, providers: [{BeamScope.Provider.Phoenix, :phoenix}]

import_config "#{config_env()}.exs"
