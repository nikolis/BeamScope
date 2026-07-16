defmodule BeamScope.DomainProvider do
  @moduledoc """
  Behaviour for a **domain provider** — a plugin that observes one runtime domain
  and contributes entities to the runtime object model (see `docs/adr/0008`).

  A provider declares the telemetry/poller sources it consumes, folds raw events
  into a local accumulator (cheap, in ETS/counters), and periodically emits a
  compact list of runtime-model structs.

  The MVP providers (`docs/ROADMAP.md`, Inc 1 & 3) are framework-independent: VM,
  Scheduler, Processes, ETS (`BeamScope.Provider.*`) — built on `:telemetry_poller`
  and runtime introspection. Future providers (Phoenix, LiveView, Presence, Oban,
  Broadway, custom metrics) plug in with **zero core change** — this is the pivot
  from "observability library with integrations" to "runtime platform with pluggable
  domain providers".

  Providers are enabled via the config-driven list (ADR-0008):

      config :beam_scope, providers: [{BeamScope.Provider.VM, :vm}, ...]
  """

  @typedoc "A telemetry event name this provider consumes."
  @type source :: [atom()]

  @doc """
  Optional one-time setup, run by the aggregator before handlers are attached.

  Use it for global side effects a provider needs, e.g. enabling a VM flag such as
  `:scheduler_wall_time`. Providers that need no setup simply omit it.
  """
  @callback setup() :: :ok

  @doc "The telemetry event sources this provider consumes."
  @callback sources() :: [source()]

  @doc """
  Optional periodic measurement, driven by the shared `:telemetry_poller` on the
  aggregation interval (`BeamScope.Aggregation.Supervisor` registers it when
  exported).

  Read runtime stats and emit them with `:telemetry.execute/3` against one of the
  events declared in `sources/0`, so `aggregate/4` folds them like any other event.
  """
  @callback poll() :: :ok

  @doc "Fold a single raw telemetry event into the provider's accumulator."
  @callback aggregate(
              event :: [atom()],
              measurements :: map(),
              metadata :: map(),
              acc :: term()
            ) :: term()

  @doc "Produce the current runtime-model entities from the accumulator."
  @callback snapshot(acc :: term()) :: [struct()]

  @optional_callbacks setup: 0, poll: 0
end
