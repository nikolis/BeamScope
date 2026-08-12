# BeamScope improvement suggestions

Suggestions for the [`nikolis/BeamScope`](https://github.com/nikolis/BeamScope) dep
(`apps/mehungry_web/mix.exs`, mounted at `/beam_scope` via `BeamScope.Exporter.Router`),
written up after a real investigation where the dashboard **misled** more than it helped.

## The motivating incident

While seeding USDA ingredient files from S3 (`S3BrowserLive` → `SeedFileImportWorker`
on the `:imports` Oban queue), the cluster dashboard showed one node as an outlier:

| Node | VM memory | Uptime | Processes | ETS | Mailbox |
|---|---|---|---|---|---|
| …20.202 | 331.9 MB | 730s | 654 | 130 · 84.0 MB | 1 · max 1 |
| **…4.21** | **1651.6 MB** | 4331s | 646 | **130 · 383.8 MB** | **261 · max 259** |
| …46.159 | 194.7 MB | 154s | 652 | 130 · 13.3 MB | 1 · max 1 |

The natural (wrong) conclusion was *"Oban isn't distributing jobs — one node is
doing all the work."* The reality was the opposite: Oban **was** distributing across
all three nodes. The hot node was simply the one **hosting the operator's LiveView
session**, and its numbers were three unrelated things stacked together:

- **Mailbox 259** — a single `S3BrowserLive` process whose mailbox filled with
  per-file PubSub status broadcasts (it re-rendered the whole table per message).
- **ETS 383.8 MB** — accumulated Cachex (`:recipes_cache`, `:geo_cache`) + Presence
  from **72 min of uptime and the most traffic**, not the seed job.
- **VM 1.65 GB** — the two above plus in-flight job heaps.

**The dashboard could not distinguish any of these.** It showed *node-level totals*
with no way to attribute them to a process, a table, or a queue. Every suggestion
below is about closing that attribution gap — and most of the data is **already
collected**, just not rendered.

---

## P1 — Render the top-N detail you already collect (cheap, highest value)

BeamScope's providers already compute exactly the drill-down that this investigation
needed; the dashboard just throws it away at render time.

- **Top processes** — `BeamScope.Provider.Processes.poll/0` already emits
  `top_mailboxes` and `top_memory` (top-N by `:message_queue_len` and `:memory`,
  with `:registered_name`). **None of it is rendered.** A "Top processes" section
  (mirroring the existing `notable_section/1` for Phoenix requests) would have
  immediately named the process holding the 259-deep mailbox.
- **Top ETS tables** — `BeamScope.Provider.ETS.poll/0` already emits `largest`
  (top-N tables by memory, with `:name`). Not rendered. This turns "383 MB of ETS"
  into "`recipes_cache` 210 MB, `geo_cache` 90 MB, …" — the difference between a
  mystery and a diagnosis.
- **Mailbox histogram** — `BeamScope.Provider.Mailbox.poll/0` already emits the
  5-bucket `distribution` (`0`, `1-9`, `10-99`, `100-999`, `1000+`). The dashboard
  shows only `total_queued`/`max_queued`. Rendering the histogram distinguishes
  "one process at 259" (our case) from "many processes mildly backed up" — very
  different problems with the same `total`/`max`.

This is a **pure exporter change** (`BeamScope.Exporter.Dashboard`) — no new polling,
no new provider, no extra runtime cost. It's the single highest-leverage fix.

## P2 — Add an Oban / queue domain provider (answers the actual fear)

The dashboard has **no notion of background jobs**, so "are jobs distributed across
nodes?" — the exact question this incident raised — is unanswerable from it. A new
`BeamScope.Provider.Oban` (plugs in with zero core change per ADR-0008) that reports,
per node:

- executing jobs **per queue** (e.g. `imports: 2/2`, `ai_agents: 0/2`) — the per-node
  concurrency limits are per-node, so seeing `imports 2 + 2 + 2` across three rows
  *is* the proof that work is spread, not siloed.
- available / retryable / scheduled backlog (cluster-shared queue depth).

Oban emits `[:oban, :job, :start | :stop | :exception]` telemetry, so this can be a
purely event-driven provider like `BeamScope.Provider.Phoenix` — no compile-time Oban
dependency. This would have replaced a 30-minute code investigation with a glance.

## P3 — Add a LiveView / socket domain provider

The load here originated from a **LiveView process**, but LiveView is invisible to
BeamScope. A provider folding `[:phoenix, :live_view, :mount | :handle_event | ...]`
plus a count of connected sockets **per node** would explain "why is this node hot"
in the common case where the answer is "it's holding N live sessions." Connected-socket
count per node is also the natural denominator for interpreting mailbox/memory outliers.

## P4 — Make outliers legible, not just visible

The table sorts by node name and leaves comparison to the eye. Two low-cost aids:

- **Flag the outlier.** Highlight a cell that's a large multiple of the cluster median
  (the 1.65 GB / 383 MB cells here). Turns "notice it yourself" into "it's marked."
- **Normalize by uptime where it matters.** The hot node also had **6× the uptime** of
  the freshest one; much of its ETS/memory is just accumulation, not live pressure.
  A "since last window" delta (the Phoenix provider already does windowed deltas via
  its `:prev` marker) for memory/ETS would separate *growing* from merely *large*.

## P5 — Attribute state to the owning OTP app / supervisor

Registered-name is often `nil` for the processes that matter (LiveView, Cowboy request
procs). Where cheap, tagging a top-N process with its `:"$initial_call"` or ancestor
supervisor would let "an anonymous pid with a 259 mailbox" read as
"a `Phoenix.LiveView` process" without the operator reverse-engineering it.

---

## Priority summary

| # | Change | Cost | Would it have solved this incident? |
|---|---|---|---|
| P1 | Render already-collected top-N processes / ETS / mailbox histogram | **Exporter only** | **Yes, instantly** |
| P2 | Oban/queue provider | New event-driven provider | Yes — answers "are jobs distributed" directly |
| P3 | LiveView/socket provider | New provider | Yes — explains the hot node |
| P4 | Outlier highlighting + uptime-normalized deltas | Exporter + reuse `:prev` | Partially — flags what to look at |
| P5 | Owning-app attribution for top-N procs | Provider tweak | Nice-to-have |

**Start with P1.** The data is already flowing to `ClusterState`; only
`BeamScope.Exporter.Dashboard` needs to render it, and it alone would have turned this
investigation into a glance.
