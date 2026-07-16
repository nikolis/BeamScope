# ADR-0008: Domain-provider plugin architecture

- **Status:** Accepted — 2026-07-15
- **Deciders:** Project architect
- **Related:** ADR-0003 (aggregation), ADR-0004 (model), ADR-0007 (exporters)

## Context

The vision lists 13 runtime domains (VM, Scheduler, Process, Mailbox, ETS, Phoenix, LiveView,
Presence, Oban, Broadway, custom, …) — a multi-year surface. If domains were wired into the core,
every new one would mean core changes, and the framework-specific ones (Phoenix, Oban) would drag
their dependencies into everyone's build. The architecture only earns the label "reference
implementation" if adding a domain is *routine*.

This is also the strategic pivot the MVP is meant to prove: once the pipeline exists, a new domain
should be **"just another plugin,"** turning BeamScope from "an observability library with
integrations" into "a runtime observability platform with pluggable domain providers."

## Decision

**Each runtime domain is a `BeamScope.DomainProvider` plugin that observes sources and contributes
entities to the runtime object model.**

```elixir
@callback sources() :: [[atom()]]                                            # telemetry events consumed
@callback aggregate(event, measurements, metadata, acc :: term()) :: term()  # fold into local accumulator
@callback snapshot(acc :: term()) :: [struct()]                              # emit runtime-model entities
@callback setup() :: :ok                                                     # optional: one-time global setup
@callback poll() :: :ok                                                      # optional: periodic measurement
```

- A provider **declares its contract**; the framework wires it on the provider's behalf: it
  attaches telemetry handlers for `sources/0`, runs optional `setup/0` once before attaching
  (e.g. enabling `:scheduler_wall_time`), and registers optional `poll/0` with the shared
  `:telemetry_poller` (which emits measurements back through the provider's own telemetry
  sources). The provider never manages global wiring.
- `aggregate/4` runs on the **hot path** and must obey ADR-0003 (bounded, lock-free, minimal work).
- `snapshot/1` runs on the **batching tick** and returns ADR-0004 model structs, which flow into
  `ClusterState` and synchronization.
- Providers are **feature-toggled via the config-driven list**
  (`config :beam_scope, providers: [{provider, domain}, ...]`) and supervised under
  `BeamScope.Aggregation.Supervisor`. A provider crash is isolated to its own domain, and the
  aggregation tick re-attaches a telemetry handler that `:telemetry` detached after a raising
  `aggregate/4`, so a hot-path fault degrades one domain briefly instead of silencing it.
- **Framework-specific providers carry their deps as `optional`** so a plain library user pulls in
  nothing extra; the provider activates only when the target lib and its telemetry are present.
- **MVP providers are framework-independent:** VM, Scheduler, Process, ETS — built solely on
  `:telemetry_poller` + runtime introspection. Phoenix/LiveView/Presence/Oban/Broadway/custom are
  future plugins added with **zero core change.**

## Consequences

### Positive
- Adding a domain is a self-contained unit of work: implement three callbacks, register the provider,
  toggle it on. This is the property that makes the roadmap tractable.
- No framework dependency is forced on users who don't use that framework (optional deps + presence
  detection).
- Fault isolation per domain: a misbehaving Oban provider cannot take down VM/Scheduler observation.

### Negative / costs
- A provider contract shared between a hot-path callback and a tick callback needs clear performance
  documentation, or a naive provider could add hot-path overhead (ADR-0003 is the guardrail).
- Optional-dependency + runtime-presence detection adds a little wiring complexity versus hardcoding.
- Growth in provider count needs a discovery/registration convention (config list of providers) to
  stay manageable.

## Alternatives considered

- **Hardcode each domain into the core.** Rejected: every domain becomes a core change and forces
  framework deps on everyone — the anti-pattern this ADR exists to prevent.
- **One giant provider with internal domain branches.** Rejected: destroys fault isolation, optional
  dependencies, and independent toggling.
- **Compile-time-only plugins (no runtime toggle).** Rejected: operators need to enable/disable
  domains per environment without recompiling (the config-driven `:providers` list).

## Failure modes & CAP

Providers are node-local (ADR-0003) and introduce no cross-node coupling, so they carry no CAP
implications of their own. Supervision isolates provider failures to a single domain's snapshots,
which self-heal on the next tick. Optional-dependency gating ensures an absent framework yields a
*disabled* provider, never a crash.
