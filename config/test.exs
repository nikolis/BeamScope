import Config

# Synchronization is disabled in unit tests; multi-node behaviour is exercised
# by dedicated integration tests (docs/ROADMAP.md, Inc 5).
config :beam_scope, sync: false

# Local aggregation (poller + provider timers) is off by default in tests so
# `ClusterState` can be driven deterministically. The pipeline integration test
# starts its own aggregation subsystem explicitly.
config :beam_scope, aggregation: false

# Keep the tick short so the pipeline integration test runs quickly.
config :beam_scope, sync_interval: 50
