import Config

# Standalone/dev: run our own Phoenix.PubSub so the default snapshot-gossip strategy has
# a transport. In an embedded deployment the host owns PubSub and sets only `:pubsub`.
# The default PubSub adapter carries broadcasts across connected nodes, so two dev nodes
# sharing this server name + a cookie will synchronize.
config :beam_scope,
  pubsub: BeamScope.PubSub,
  start_pubsub: true,
  # Serve the Prometheus (/metrics) + dashboard (/) endpoints standalone in dev.
  exporter: [port: 9568]
