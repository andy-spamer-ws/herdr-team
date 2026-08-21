# Agent Traceability for herdr-team — Source-Grounded Design and Impact Assessment

Assessment only. No files were modified in either repository.

- Source: `/home/wa11gf/01-utils/super-simple-software-factory` (branch `main`, untracked `.specs/` only)
- Target: `/home/wa11gf/01-utils/herdr-team` (branch `main`, modified `README.md`, `agents/orchestrator.md`, `bin/ccd`, `bin/ccw`, `skills/orchestrate/SKILL.md`; untracked `tests/`)

Brief path note: the brief cites source paths as `factory/f_modules/*`. Those files ship at
`.claude/skills/sssf/templates/factory/f_modules/*`; `/factory/` at the source repo root is a
gitignored dogfood install (`.gitignore`, "Dogfood install: a stamped factory at the repo root").
All citations below use the shipped template paths.

---

## Part 1 — The source event model, traced end to end

### F1. Two stores, one writer, no transport

`tracer.py:1-6` states the contract: "every event lands in JSONL and SQLite AS IT HAPPENS…
No push transport — the flow is always: agents -> sqlite -> web ui."

`Tracer.event()` (`tracer.py:123-136`) performs both writes in one call:

- appends one JSON line to `events.jsonl` (`tracer.py:127-129`)
- inserts one row into `events` (`tracer.py:130-135`)

`references/observability.md:5-9` frames the durability rule: files are the raw record, SQLite is
the queryable mirror, "Losing the db loses nothing that can't be rebuilt from files."

### F2. Schema — seven tables, created by the producer

`tracer.py:17-92` holds the full DDL as a string constant, applied with `executescript` in the
constructor (`tracer.py:112`). Tables: `sessions` (`:18-27`), `phases` (`:28-37`), `events`
(`:38-48`), `envelopes` (`:49-59`), `gate_results` (`:60-70`), `processes` (`:71-79`),
`agent_sessions` (`:80-91`).

The producer owns schema creation entirely. `CREATE TABLE IF NOT EXISTS` means the first write by
any producer process materialises a complete database. No migration tool, no viewer, no install
step is involved.

Additive migration is an explicit list (`tracer.py:94-100`) replayed by `_migrate()`
(`tracer.py:115-121`), which reads `PRAGMA table_info` and issues `ALTER TABLE ADD COLUMN` for
anything missing. The comment at `tracer.py:93-95` gives the reason: "CREATE TABLE IF NOT EXISTS
never revisits an existing table, so additive changes need an explicit ALTER."

### F3. Event envelope

The in-process event contract is `EventRecord` (`data_types.py:354-368`):

| Field | Line | Meaning |
|---|---|---|
| `f_id` | `:357` | session correlation id (required) |
| `phase_id` | `:358` | phase correlation id, default `""` |
| `type` | `:359` | one of ten types |
| `name` | `:360` | human label |
| `payload` | `:361` | free-form dict |
| `parent_id` | `:362` | span nesting |
| `tokens` | `:363` | optional cost measure |
| `started_at` / `ended_at` | `:367-368` | span columns; both set only for events covering real elapsed time |

`event_id` and `ts` are minted inside the tracer, not by the caller (`tracer.py:124-126`),
using `new_id(12)` → `secrets.token_hex` (`utils.py:41-42`) and `now_iso()` → UTC ISO-8601 at
millisecond precision (`utils.py:45-46`).

### F4. Taxonomy — ten types

Declared in the producer comment (`data_types.py:359`), documented in
`references/observability.md:13-26`, and mirrored as a closed union in the viewer's
`shared/types.ts:19-30`:

`phase_start`, `phase_end`, `agent_start`, `agent_end`, `tool_call`, `handoff`, `gate_pass`,
`gate_fail`, `log`, `error`.

Payload shapes for the three the UI parses are documented as optional-everything interfaces in
`shared/types.ts:203-263` (`AgentStartPayload`, `AgentEndPayload`, `ToolCallPayload`), with the
stated reason at `shared/types.ts:196-199`: "every field is optional because the tracer writes what
the coding agent reported, which varies by agent and by version." The reader tolerates producer
variance; the producer never negotiates with the reader.

### F5. Correlation and identity

- `f_id` — minted in `session.ensure()` (`session.py:39`) as `new_id(8)`, or pinned by the caller
  so a second workflow joins the same session.
- `phase_id` — composed, not random: `f"{self.f_id}_{self._seq:02d}_{params.name}"`
  (`runner.py:75`), making it stable, sortable and human-readable.
- `seq` — continued rather than restarted for a joined run, via `max_phase_seq()`
  (`tracer.py:206-216`). The docstring states the failure it prevents: restarting at 1 "would
  collide with the first run's phases on both `seq` (breaking ordering) and `phase_id` (silently
  overwriting a row through the phase_upsert conflict clause)."
- `parent_id` — span nesting, so an agent phase expands into its tool calls
  (`references/observability.md:28`).

### F6. Lifecycle hooks — where events actually come from

| Hook | Site | Emits |
|---|---|---|
| Session open | `session.py:38-49` | `session_start` row + `process_start` for the FW pid |
| Phase enter | `runner.py:73-87` | `phase_upsert` + `phase_start` |
| Explicit log | `runner.py:27-34` | `log`, plus `session_request` when an engineer phase logs `input` |
| Console output | `console.py:40-47` | every printed line is also a `log` event — "print AND trace, always together" (`console.py:39`) |
| Agent spawn | `agents.py:101-110` | `agent_start` with model, thinking, color, session id, tools, extensions |
| Child process | `agents.py:136-139` | `process_start` / `process_end` via `on_spawn` / `on_exit` callbacks |
| Tool call | `agents.py:241-257` | one `tool_call` per real call, span columns popped out of the record (`:252-253`) |
| Gates | `agents.py:159-166` | `gate_row` + `gate_pass`/`gate_fail` carrying `attempt`, `violations`, `checks` |
| Permission breach | `agents.py:187-192` | `error` |
| Paths touched | `agents.py:194-196` | `log` |
| Handoff / agent close | `agents.py:206-215` | `handoff`, then `agent_end` with phase-total usage |
| Phase exit | `runner.py:88-112` | `error` + `phase_end(fail)` on exception, `phase_end(success)` on clean exit |
| Run finish | `runner.py:114-142` | optional `not_accepted` error + `session_finish` |

### F7. Streaming, not batching

`agents.py:241-257` (`_event_forwarder`) is handed to the adapter as `on_event`
(`agents.py:135`), and the adapter invokes it per line of the child's JSONL stdout
(`agent_pi.py:285-286`, `agent_cc.py:441-442`). `references/observability.md:59` states the
consequence: events are inserted "while the agent is still working — never batched at phase end."

### F8. Failure behaviour

Three distinct policies, all in the producer:

1. **Success must be earned.** `phases.status` defaults to `'fail'` in the DDL (`tracer.py:33`);
   only a clean context-manager exit writes `success` (`runner.py:104-112`).
2. **A killed run closes its own trace.** `session.py:21-35` converts `SIGTERM`/`SIGINT` into
   `SystemExit`, calling `session_finish(ok=False)` first. The docstring names the failure it
   prevents: otherwise "the session reading `running` forever and its process rows open — the trace
   would claim work is in flight that is already dead."
3. **The db, the banner and the exit code cannot disagree.** `runner.py:114-142` documents a fixed
   bug where a property with side effects "recorded green in the db, on the terminal, and in the UI
   while exiting 1."

**Gap worth naming:** there is no isolation around tracer failure itself. `Tracer.event()`
(`tracer.py:123-136`) is unguarded, so a locked or unwritable database raises into the workflow and
kills the run. Acceptable when the workflow *is* the Python process; unacceptable for the target
(see R2).

### F9. Viewer read path — mostly read-only, with one archive-state write

**Precise claim: the SSSF viewer is *mostly* read-only, not strictly read-only.** It holds a
read connection opened `{ readonly: true }` (`server/db.ts:77`) on which the header comment
(`server/db.ts:3-12`) states every query is a `SELECT` — but it also has **a separate archive-state
write**. `setArchived` (`server/db.ts:141-148`) opens a *second, lazy, writable* connection
(`server/db.ts:144-147`) and updates `sessions.archived`. That column is declared reader-owned in
the producer DDL — "review triage, set by the UI; never by a run" (`tracer.py:26`) — and
`references/observability.md:135-139` describes it as "the reader's state living on the row."

So the source viewer has two connections with two postures: a strictly read-only one for all
trace data, and a narrow writable one for a single annotation column. **The target does not adopt
the second** (see D10): mixing a writable reader connection into the producer's event database
weakens the very isolation this design exists to guarantee, and gives a reader a lock it can hold
against producers.

The reader cannot run the producer's ALTERs and says so (`server/db.ts:98-101`); it probes for
column existence with a cache (`server/db.ts:65`, `:113-116`).

Polling is a rowid cursor (`server/db.ts:368-382`), matching the documented contract at
`references/observability.md:145-155`. `shared/types.ts:79-80` names `rowid` as "the polling
cursor. Monotonic, insertion-ordered."

**Decoupling verified by search.** `rg` across all producer Python for `visualizer`, `import.*apps`,
`localhost:` and `http://` returns nothing. The producer's only imports are `json`, `sqlite3`,
`pathlib` (`tracer.py:10-12`) plus sibling factory modules (`:14-15`). There is no ingest endpoint,
no WebSocket, no dedup or backfill logic — `references/observability.md:141-143`: "The UI never
receives pushes."

### F10. Reusable concepts vs factory-specific coupling

| Reusable | Factory-specific |
|---|---|
| Append-only durable record on disk, with SQLite as a rebuildable query mirror (`observability.md:5-9`) | `envelopes` table — typed agent output contracts |
| WAL + `synchronous=NORMAL` + `busy_timeout=5000` on every connection (`tracer.py:109-111`, `server/db.ts:82-83`) | `gate_results` — the gate/correction loop |
| Producer-created schema, additive ALTER migrations | `phases` as a context manager with earned success |
| Rowid cursor polling, one mechanism for live and history | Token/cost accounting and `context_tokens` occupancy |
| Correlation as `session id → phase id → event`, `parent_id` for spans | `agent_sessions` mirroring `agent_map.json` |
| `processes` table answering "what is running and how do I stop it" | Pydantic `EventRecord` validation |
| Optional-everything payload typing in the reader | In-process `Tracer` object passed through a `Run` |
| — | Coding-agent JSONL stdout adapters |
| **Rejected, not reused:** reader-owned columns in the producer db (`archived`, `tracer.py:26`; `setArchived`, `server/db.ts:141-148`) — a writable reader connection is exactly the coupling the target must not inherit (D10) | |
| **Rejected, not reused:** unguarded, unversioned, unbounded dual write (`tracer.py:123-136`) — replaced by the spool/replay policy in D7 and the versioning in D3 | |

The single most transferable structural property: **the producer is a library with no network, no
reader dependency, and no configuration beyond a file path** (`session.py:40-41` passes
`cfg.observability.db` and a JSONL path; `sssf.config.yaml:35-37` declares them).

---

## Part 2 — Herdr Team lifecycle map

### F11. What exists today

`herdr-team` is a bash bundle. There is **no observability of any kind**: `rg -i` for
`log|trace|event|audit|jsonl|sqlite` across `bin/`, `lib/` and `install.sh` returns nothing but the
word "log" in unrelated contexts. There is no CI (`.github` absent) and `tests/` is untracked and
referenced by nothing.

Existing dependency surface, which the design must not widen: `bash`, `python3`, `herdr`,
`copilot`, `git`. `python3` is already required and used for JSON parsing in `bin/ccw:178-196`
(`json_get`) and `bin/ccd:129-134`, `:136-160`, `:176-183`.

### F12. Deterministic emission points — real code, guaranteed to run

**`bin/ccw` (worker dispatch):**

| Line range | Moment | Proposed event |
|---|---|---|
| `bin/ccw:126-146` | name + role validated, model resolved | `dispatch_start` |
| `bin/ccw:212-250` | pane acquired (tab create / split named tab / split current) | `pane_acquired` |
| `bin/ccw:256-260` | `herdr pane rename` succeeded or failed into `cleanup_pane` | `pane_labeled` / `dispatch_fail` |
| `bin/ccw:262-271` | `herdr agent start` succeeded or failed into `cleanup_pane` | `agent_started` / `dispatch_fail` |
| `bin/ccw:273-275` | final success line printed | `dispatch_ok` |
| `bin/ccw:152-176` | `--dry-run` path exits 0 without launching | emit nothing |

`bin/ccw:34` sets `set -euo pipefail`. This is the single most important constraint on the
emitter's call convention (R2).

**`bin/ccd` (orchestrator boot):**

| Line range | Moment | Proposed event |
|---|---|---|
| `bin/ccd:116-119` | already inside herdr, renames own pane, `exec`s copilot | `orchestrator_started` |
| `bin/ccd:165-197` | `spawn_copilot` — tab create, rename, `agent start` | `orchestrator_started` / `orchestrator_start_fail` |
| `bin/ccd:122-125` | herdr not on PATH, runs copilot bare | `orchestrator_started` with `degraded=no_herdr` |

**`lib/roles.sh:21-33`** is the role→model mapping. Every event carrying a role should carry the
resolved model too, captured via `roles_model` (`lib/roles.sh:36-41`), already called at
`bin/ccw:139`.

### F13. Advisory emission points — instructions in Markdown, executed by an LLM

These are the phases that carry the delivery meaning, and none of them is code:

| SKILL.md lines | Phase | Proposed event |
|---|---|---|
| `:69-73` | Scope — the brief is written | `batch_start`, `scope` |
| `:75-105` | Space — workspace/tab resolved via `herdr pane get` | `topology_resolved` |
| `:107-122` | Route — substrate chosen | `route_decided` |
| `:205-233` | `git worktree add` / `remove` / `prune` | `worktree_add`, `worktree_remove` |
| `:235-257` | Service tab + `herdr workspace report-metadata` | `service_registered`, `service_token_cleared` |
| `:259-267` | `herdr agent prompt <name> "<brief>" --wait` | `prompt_sent` |
| `:293-317` | Supervise — `agent wait`, `agent read`, timeouts | `agent_settled`, `wait_timeout` |
| `:354-368` | Verify — mandatory, verifier never sees the worker's report | `verify_result` |
| `:370-409` | Review — optional; verdict line `REVIEW: CLEAR` / `REVIEW: BLOCKED` | `review_verdict` |
| `:411-416` | Correct once — one correction, then escalate | `correction_sent`, `escalated` |
| `:418-449` | Clean up — `agent get`, `pane close`, worktree removal | `pane_closed`, `cleanup_done` |
| `:451-457` | Report | `batch_end` |

### F14. The central structural difference

In the source, the control loop is a deterministic Python process that both *decides* and
*records* — `runner.py:73-112` cannot advance a phase without writing its events.

In herdr-team, the control loop is an LLM reading `skills/orchestrate/SKILL.md`. Only `ccw` and
`ccd` are real code. Every event in F13 is therefore **advisory**: it happens if and only if the
orchestrator chooses to run a command.

This is not a detail to smooth over. A trace that mixes guaranteed and best-effort records without
distinguishing them is worse than no trace, because it reads as authoritative. The schema must
carry the distinction (D4).

### F15. A blocking conflict in the current orchestrator contract

`agents/orchestrator.md` ("Bash is not a loophole") forbids the orchestrator from running, with
"no exceptions": redirections that create or truncate files, heredocs, in-place editors, `mkdir`,
`mv`, `cp`, `rm`, `touch`, and package/build/test tooling. The one carve-out is
`git worktree add|remove|prune`.

An event emitter creates and writes a database file. Under the rules as written, a
correctly-behaving orchestrator will refuse to emit any advisory event. This must be resolved
explicitly in `agents/orchestrator.md` before Stage 4 (see A4-1), not left to interpretation.

---

## Part 3 — Target architecture

### D1. Producer boundary: one executable, callable from bash

Add `bin/ccevent` — a stdlib-only `python3` script. It is the only component that knows the
schema, and the only writer.

```
ccevent emit --type <type> --batch <id> [--agent NAME] [--role R] [--model M]
             [--pane P] [--tab T] [--workspace W] [--cwd PATH] [--status S]
             [--key IDEMPOTENCY_KEY] [--payload-json '{...}'] [--payload k=v ...]
             [--source ccw|ccd|orchestrator]     # confidence is derived from this
ccevent batch new [--label L]         # mints and prints a batch id
ccevent flush [--max N] [--deadline MS]  # drain spool -> SQLite; safe to run anytime
ccevent status [--json]               # backlog depth, dropped counter, last flush, versions
ccevent migrate [--dry-run]           # additive schema upgrade, producer-only
ccevent prune  --older-than 30d | --keep-batches 200 [--dry-run]
ccevent purge  --batch <id> | --all [--yes]   # irreversible, removes spool + rows + JSONL
ccevent show <batch> | tail [--follow]   # read-only text reader
ccevent path [--spool|--db]           # prints resolved paths
ccevent doctor [--json]               # read-only self-check, never writes
```

Rationale for `python3` over pure bash: `sqlite3(1)` is not guaranteed present on macOS or minimal
Linux images, while `python3` is already a hard dependency of `bin/ccw:178-196` and
`bin/ccd:129-134`. `sqlite3`, `json`, `os`, `hashlib` and `secrets` are all stdlib. **Zero new
dependencies.**

Add `lib/trace.sh`, sourced by `ccw` and `ccd` the same way `lib/roles.sh` already is
(`bin/ccw:63-64`, `bin/ccd:64-65`), exposing one function:

```bash
trace_emit <type> [args...]   # never fails, never blocks, never prints on the happy path
```

### D2. Storage — canonical spool, derived database

Two stores with an explicit hierarchy. Unlike the source, which writes both stores inline and
treats neither as recoverable from the other in code (`tracer.py:123-136`), the target names one
canonical and makes the other strictly derivable.

| | Path | Role |
|---|---|---|
| **Spool (canonical)** | `${CCT_TRACE_HOME:-$HOME/.local/state/herdr-team}/spool/<batch_id>.jsonl` | Append-only NDJSON. One `write()` per event, `O_APPEND`, `O_CREAT`. The record of truth. |
| **Database (derived)** | `${CCT_TRACE_DB:-$CCT_TRACE_HOME/trace.db}` | SQLite query mirror. Entirely rebuildable from the spool by `ccevent flush`. |
| **Archive** | `$CCT_TRACE_HOME/archive/<batch_id>.jsonl.gz` | Post-retention compressed spool, if `CCT_TRACE_ARCHIVE=1`. |

Design consequences:

- **Losing the db loses nothing.** This is the source's stated property
  (`references/observability.md:5-9`) made mechanically true: `ccevent flush --rebuild` reconstructs
  every table from spool files alone.
- **Default location is outside any repo**, unlike the source's in-repo `factory/f_data/sssf.db`
  (`sssf.config.yaml:36`). herdr-team dispatches across many repos and worktrees; a per-repo db
  would fragment one batch across several files. `.gitignore` still gains a defensive entry for
  the override case.
- **Every SQLite connection, writer and reader**, opens with `PRAGMA journal_mode=WAL`,
  `synchronous=NORMAL`, `busy_timeout=5000` — from `tracer.py:109-111`, matched read-side at
  `server/db.ts:82-83`.
- **Local access permissions.** `$CCT_TRACE_HOME` and every subdirectory are created `0700`;
  spool files, `trace.db`, `trace.db-wal`, `trace.db-shm` and archives are created `0600`; the
  process sets `umask 077` before any create so a permissive inherited umask cannot widen them.
  `ccevent doctor` FAILs if any path is group- or world-readable, and `ccevent` refuses to write to
  a `$CCT_TRACE_HOME` it does not own. The source specifies no permissions at all; this is an
  addition, not a port.

### D3. Event envelope — explicitly versioned

Two independent version numbers, because they change for different reasons and readers need to
distinguish them:

- **`schema_version`** — the shape of the SQLite tables. Owned by `ccevent`, bumped when a
  migration runs.
- **`event_version`** — the shape of a single event record as written to the spool. Stamped on
  **every** event row and every NDJSON line, so a spool file that outlives several producer
  versions is still parseable line by line.

```sql
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- seeded by the producer on first open:
--   schema_version        = '3'      (integer, monotonic)
--   min_reader_version    = '1'      (oldest reader that can still read correctly)
--   producer_version      = '0.4.0'  (bundle version that last wrote)
--   created_at            = ISO-8601

CREATE TABLE IF NOT EXISTS batches (
  batch_id     TEXT PRIMARY KEY,
  label        TEXT,
  repo         TEXT,
  orchestrator TEXT,            -- ccd agent name
  workspace_id TEXT, tab_id TEXT,
  status       TEXT DEFAULT 'running',   -- running | success | fail | abandoned
  started_at   TEXT, ended_at TEXT
);

CREATE TABLE IF NOT EXISTS agents (
  batch_id   TEXT REFERENCES batches,
  agent      TEXT,              -- the ccw <name>: unique among live agents
  role       TEXT, model TEXT,
  pane_id    TEXT, tab_id TEXT, workspace_id TEXT,
  cwd        TEXT,              -- the worktree
  status     TEXT DEFAULT 'dispatched',
  started_at TEXT, ended_at TEXT,
  PRIMARY KEY (batch_id, agent)
);

CREATE TABLE IF NOT EXISTS events (
  event_id      TEXT PRIMARY KEY,   -- stable, content-derived (D6)
  event_version INTEGER NOT NULL,   -- record shape, stamped per event
  batch_id      TEXT REFERENCES batches,
  agent         TEXT,               -- NULL for batch-level events
  parent_id     TEXT,               -- span nesting, as tracer.py
  type          TEXT,
  name          TEXT,
  source        TEXT,               -- 'ccw' | 'ccd' | 'orchestrator' | 'unknown'
  confidence    TEXT,               -- 'deterministic' | 'advisory'  (producer-derived)
  status        TEXT,               -- ok | fail | blocked | timeout | skipped
  payload_json  TEXT,
  idem_key      TEXT,
  emitted_at    TEXT NOT NULL,      -- producer wall clock at emit
  ingested_at   TEXT NOT NULL,      -- when flush wrote the row
  seq           INTEGER NOT NULL,   -- per-batch monotonic emit counter (D6)
  started_at    TEXT, ended_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS events_idem ON events(batch_id, idem_key)
  WHERE idem_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS events_batch ON events(batch_id, seq);
CREATE INDEX IF NOT EXISTS events_cursor ON events(batch_id, rowid);

CREATE TABLE IF NOT EXISTS spool_loss (         -- overflow accounting, D7
  batch_id   TEXT,
  dropped    INTEGER,
  first_at   TEXT, last_at TEXT,
  reason     TEXT,                 -- 'capacity' | 'unwritable' | 'corrupt_line'
  PRIMARY KEY (batch_id, reason)
);
```

The NDJSON line carries the same envelope plus its version, so it self-describes:

```json
{"event_version":1,"event_id":"…","batch_id":"…","seq":42,"emitted_at":"…",
 "type":"agent_started","source":"ccw","confidence":"deterministic","payload":{…}}
```

**Additive migration compatibility contract.** Ported from the source's `MIGRATIONS` list
(`tracer.py:94-100`) and `_migrate()` (`tracer.py:115-121`), tightened into rules:

1. **Additive only.** New optional columns and new tables. Never drop, rename, retype or narrow a
   column; never add a `NOT NULL` without a default; never change a primary key.
2. **Producer-only.** Only `ccevent migrate` (run implicitly on producer open, explicitly by
   `orchestrate-doctor`) issues DDL. Readers are read-only and structurally cannot migrate — the
   source reader states exactly this limitation at `server/db.ts:98-101`.
3. **Old reader, new db.** A reader at version *N* must keep working against `schema_version > N`
   as long as `meta.min_reader_version <= N`, by selecting named columns only, never `SELECT *`,
   and probing `PRAGMA table_info` for optional columns with a cache — the pattern already used at
   `server/db.ts:65`, `:113-116`.
4. **New reader, old db.** A reader must treat any absent column as null-valued rather than an
   error, mirroring the source's stance that historical rows simply lack fields
   (`shared/types.ts:196-199`, `:150-156`).
5. **Old spool, new producer.** `ccevent flush` dispatches on each line's `event_version` and
   upgrades in memory. Lines whose `event_version` exceeds the producer's own are copied to
   `$CCT_TRACE_HOME/quarantine/` and counted, never silently dropped.
6. **`min_reader_version` is raised only by a breaking change** — which, by rule 1, requires a new
   table rather than an altered one. Raising it is a deliberate, documented act.
7. **Unparseable spool line** — counted into `spool_loss` with `reason='corrupt_line'`, the line
   copied to quarantine, and the flush continues. One bad line never blocks a batch.

### D4. Taxonomy, with the honesty field

Deterministic (`source` in `ccw`/`ccd`, `confidence='deterministic'`):
`orchestrator_started`, `dispatch_start`, `pane_acquired`, `pane_labeled`, `agent_started`,
`dispatch_ok`, `dispatch_fail`.

Advisory (`source='orchestrator'`, `confidence='advisory'`):
`batch_start`, `scope`, `topology_resolved`, `route_decided`, `worktree_add`, `worktree_remove`,
`prompt_sent`, `agent_settled`, `wait_timeout`, `verify_result`, `review_verdict`,
`correction_sent`, `escalated`, `pane_closed`, `service_registered`, `service_token_cleared`,
`cleanup_done`, `batch_end`, `log`, `error`.

`confidence` is set by `ccevent` from the invoking `--source`, not accepted from the caller. It is
what lets a reader say "the batch has no `verify_result`" and be correct about whether that means
verification did not happen or merely was not recorded.

### D5. Correlation IDs

| Id | Origin | Notes |
|---|---|---|
| `batch_id` | `ccevent batch new`, exported as `CCT_BATCH_ID` | one orchestrate invocation |
| `agent` | the `ccw <name>` argument (`bin/ccw:120-133`) | already validated unique among live agents (`SKILL.md:136-137`) |
| `pane_id` / `tab_id` / `workspace_id` | herdr JSON responses (`bin/ccw:217-218`, `:236-242`) | herdr topology |
| `cwd` | `--cwd` (`bin/ccw:98`) | the worktree, ties events to a branch |
| `event_id` | minted in `ccevent` | never accepted from the caller, per `tracer.py:124` |

**Fallback when `CCT_BATCH_ID` is unset** (a bare `ccw` outside an orchestrate invocation): derive
`batch_id` from the resolved `tab_id` as `tab-<tab_id>` and set `batches.label='(derived)'`. The
event is still recorded and still correlated; it is never dropped for want of a batch.

### D6. Identity, idempotency and ordering

**Stable `event_id`.** Unlike the source, which mints a random `evt_{token_hex(12)}` inside the
tracer (`tracer.py:124`, `utils.py:41-42`), the target derives it deterministically so that
replaying the same spool line any number of times produces the same row:

```
event_id = "evt_" + sha256(batch_id | source | seq | type | emitted_at | canonical_payload)[:24]
```

Random ids cannot survive replay — that is precisely why the source's design tolerates no retry.
A content-derived id makes flush, re-flush and full rebuild idempotent by construction.

**`idem_key`** is a separate, *semantic* key for de-duplicating a repeated logical event, not a
repeated write:

- Deterministic emitters use natural keys: `<agent>:dispatch_start`, `<agent>:agent_started`.
- Advisory emitters pass a key for anything a retrying orchestrator may repeat: `verify_result`,
  `review_verdict`, `batch_end`.
- Enforced by the partial unique index in D3, applied with `INSERT OR IGNORE`.

The two are orthogonal: `event_id` collapses duplicate *writes* of one record; `idem_key`
collapses duplicate *emissions* of one fact.

**Ordering semantics, stated precisely.** Three fields, three different guarantees. A reader must
know which to use:

| Field | Guarantee | Use for |
|---|---|---|
| `seq` | Per-batch, per-process monotonic emit counter, allocated at emit time before the spool write | Ordering events *within* one batch |
| `rowid` | Global monotonic insertion order into SQLite | The polling cursor only (`server/db.ts:368-382`, `shared/types.ts:79-80`) |
| `emitted_at` | Producer wall clock, millisecond ISO-8601 (`utils.py:45-46`) | Display and duration, never ordering |

Explicit non-guarantees, so no reader assumes more than is true:

1. **`rowid` order is not emit order.** A spooled event flushed late lands at a higher `rowid` than
   an event emitted after it but flushed first. `rowid` is a cursor, not a clock.
2. **`seq` is total within one writer, partial across writers.** Concurrent `ccw` processes and
   the orchestrator each allocate from the same per-batch counter file under an `O_EXCL` lock, so
   `seq` is unique per batch; where two processes interleave, relative order between them reflects
   counter acquisition, not causality.
3. **Wall clocks are not comparable across processes** and must never be used to sort.
4. **Total causal order is not provided.** `parent_id` expresses the only causal relation the
   design claims, exactly as in the source (`references/observability.md:28`).

A reader rendering a batch sorts by `seq`; a reader tailing live data pages by `rowid` and then
sorts the page by `seq`.

### D7. Durability — bounded spool, replayed into SQLite, never blocking

The source writes JSONL and SQLite inline in one unguarded call (`tracer.py:123-136`). A locked or
unwritable database therefore raises into the workflow and kills the run. That is defensible when
the workflow *is* the Python process. It is unacceptable here: `bin/ccw:34` runs
`set -euo pipefail`, so the same failure would abort a dispatch and strand a bare pane. The target
replaces the dual write outright.

**D7.1 Canonical record and write order.** The spool NDJSON line is canonical. SQLite is derived.
Emission is exactly one ordered sequence, and it stops at step 3:

1. Allocate `seq` from the per-batch counter (`O_EXCL` lock file, `flock`, 200 ms cap).
2. Build the envelope, redact (D9), compute `event_id` (D6).
3. `open(O_WRONLY|O_APPEND|O_CREAT, 0600)`, one `write()` of one `\n`-terminated line under an
   advisory `flock(LOCK_EX)`, then `close()`. **Emission returns here.**
4. SQLite ingestion happens *later and elsewhere* — never on the emit path.

A single `write()` of a line below `PIPE_BUF`/page size is atomic enough in practice for `O_APPEND`
on a local filesystem; the `flock` covers the rest. No `fsync` on the emit path: a machine-crash
window of a few events is an acceptable trade for never blocking a dispatch, and is stated openly
rather than implied.

**D7.2 Who replays, and when.** `ccevent flush` drains spool → SQLite. It is triggered
opportunistically, never synchronously blocking a caller:

- At the *end* of `ccd`'s startup path, detached and niced, after the pane is up.
- By `ccevent status`, `show`, `tail` and `doctor` before they read.
- Manually, and by any reader that wants fresh data (a reader may *invoke the producer CLI*; it
  must never write SQLite itself — D10).
- Never from inside `ccw`'s dispatch path.

Flush is a single writer guarded by `$CCT_TRACE_HOME/flush.lock` (`flock(LOCK_EX|LOCK_NB)`); a
second flush simply exits 0. Progress per batch is a byte offset in `spool/<batch_id>.offset`,
written **after** the SQLite transaction commits, so a crash between the two replays the tail
rather than losing it. Replay is safe because `event_id` is content-derived (D6) and inserts are
`INSERT OR IGNORE`.

`batches` and `agents` are projections rebuilt by flush from the event stream — the same
relationship `sessions`/`phases` have to events in the source — never written by `emit`.

**D7.3 Retry and reconciliation.**

- `emit` does not retry SQLite, because it never touches SQLite.
- `emit` retries the spool write once on `EINTR`/`EAGAIN`, then gives up (D7.5).
- `flush` retries a `SQLITE_BUSY` transaction with backoff 50/100/200/400 ms on top of
  `busy_timeout=5000` (`tracer.py:111`); on continued failure it leaves the offset unadvanced and
  exits 0 — the data is still canonical on disk.
- On `SQLITE_CORRUPT` or `NOTADB`, flush renames the db to `trace.db.corrupt.<ts>`, recreates it,
  resets **all** offsets to 0 and rebuilds from spool. Full recovery, no operator action.
- **Cross-store inconsistency is defined away**: the spool is truth and the db is a cache, so they
  cannot disagree — the db can only be *behind*. `ccevent status` reports that lag as
  `pending_events` per batch, and `doctor` WARNs above a threshold. There is no reverse
  reconciliation, and SQLite is never a source for the spool.

**D7.4 Capacity limits.** Bounded, not unbounded:

| Bound | Default | Env | On breach |
|---|---|---|---|
| Per-batch spool file | 32 MB | `CCT_SPOOL_MAX_BATCH` | drop + count (D7.5) |
| Total spool directory | 512 MB | `CCT_SPOOL_MAX_TOTAL` | drop + count |
| Single payload | 64 KB | `CCT_PAYLOAD_MAX` | payload truncated, `payload_truncated:true` set — the event itself is kept |
| Unflushed backlog | 50 000 events | `CCT_SPOOL_MAX_PENDING` | drop + count |
| Emit wall time | 500 ms soft / 5 s hard | `CCT_EMIT_TIMEOUT` | abandon the write, count as loss |

**D7.5 Overflow and loss behaviour — loud, never silent.** The source has no concept of dropping,
because it cannot drop; it fails instead. The target drops, so it must account:

1. Capacity breach → the event is **not** written. A counter file
   `spool/<batch_id>.dropped` is incremented (`reason`, `first_at`, `last_at`).
2. Flush projects those counters into the `spool_loss` table (D3), so loss is queryable next to the
   data it is missing from.
3. A `trace_loss` **event** is emitted into the spool on the first drop per batch per reason, and
   at most once per minute after — so the gap is visible in the stream itself, not only in a
   sidecar table.
4. **Drop policy is oldest-first for `log`-class events and newest-first never**: lifecycle events
   (`dispatch_*`, `agent_started`, `verify_result`, `review_verdict`, `batch_end`) are
   never dropped ahead of a `log` event. Losing chatter is acceptable; losing the outcome is not.
5. A reader must render any batch with `spool_loss` rows or a `trace_loss` event as **incomplete**,
   and must not compute completeness metrics over it.

**D7.6 Non-blocking guarantees at the bash boundary.** In `lib/trace.sh`:

```bash
trace_emit() {
  [ "${CCT_TRACE:-1}" = 1 ] || return 0
  command -v ccevent >/dev/null 2>&1 || return 0
  ( timeout "${CCT_EMIT_TIMEOUT:-5}" ccevent emit "$@" \
      >/dev/null 2>>"${CCT_TRACE_ERRLOG:-$CCT_TRACE_HOME/emit.err}" ) || true
  return 0
}
```

Every clause is load-bearing under `bin/ccw:34`: the subshell contains `set -e` effects,
`timeout` bounds a hung emitter, `|| true` neutralises any exit code, stderr is redirected so
`ccw`'s machine-readable success line (`bin/ccw:273-275`) is untouched, and `return 0` makes the
function safe in any position. `CCT_TRACE=0` short-circuits before `python3` is ever started —
required for `--dry-run` (`bin/ccw:152-176`) and for tests.

**D7.7 Termination.** Unlike `session.py:21-35`, `ccw` is short-lived and does not own the agent's
lifetime, so it must not fabricate a terminal state. `batch_end` is advisory. A reader classifies a
batch with no `batch_end` and no event for `CCT_BATCH_STALE` (default 6 h) as `abandoned`, and
`ccevent status` reports it as such. Nothing writes a fake outcome — the same discipline behind the
source's "success must be earned" (`tracer.py:33`, `runner.py:104-112`).

**D7.8 Doctor exposure.** `orchestrate-doctor` surfaces all of it through the existing
`pass`/`warn`/`fail` helpers (`bin/orchestrate-doctor:78-80`):

| Check | PASS | WARN | FAIL |
|---|---|---|---|
| spool writable, `0600`, owned by user | yes | — | no |
| backlog `pending_events` | < 1 000 | ≥ 1 000 | ≥ `CCT_SPOOL_MAX_PENDING` |
| dropped events (all batches, 7 d) | 0 | ≥ 1 | ≥ 1 000 |
| spool total size | < 50 % of cap | ≥ 50 % | ≥ 90 % |
| last successful flush | < 1 h | ≥ 24 h | — |
| `emit.err` size | 0 | > 0 | — |
| `schema_version` vs producer | equal | db older, migration pending | `min_reader_version` > reader |
| quarantined lines | 0 | ≥ 1 | — |

`ccevent status --json` gives the same numbers machine-readably. Loss is never inferable only by
absence.

### D8. Retention, purge and lifecycle of stored data

The source has none — `sssf.db` grows unbounded, and nothing in `tracer.py` or
`references/observability.md` bounds it. Fully specified for the target.

**Retention triggers.** Whole batches only, never partial, so a retained batch is always internally
consistent:

| Rule | Default | Env |
|---|---|---|
| Age — batch `ended_at` (or last event) older than | 30 days | `CCT_RETAIN_DAYS` |
| Count — keep the most recent N batches | 200 | `CCT_RETAIN_BATCHES` |
| Size — total store above cap, evict oldest until under | 512 MB | `CCT_RETAIN_MAX_BYTES` |

A batch is eligible only when it is terminal (`success`, `fail`, `abandoned`) **and** fully flushed
(offset at EOF). A `running` batch is never pruned regardless of age.

**`ccevent prune`** reclaims space while preserving accounting. Per eligible batch, in one
transaction: delete its `events`, `agents` and `batches` rows; delete the spool file, or gzip it to
`archive/` when `CCT_TRACE_ARCHIVE=1`; delete offset and counter files; **retain** the `spool_loss`
row; and insert a `batches` tombstone (`batch_id`, `status`, `started_at`, `ended_at`, `pruned_at`)
so a reader can tell "this batch never existed" from "this batch aged out". `--dry-run` lists what
would go without touching anything.

**`ccevent purge`** is irreversible deletion for a privacy request or a leaked secret:
`--batch <id>` or `--all`, requires `--yes`, and removes rows, spool, offsets, counters, archives
**and** tombstones, then `VACUUM`s. Leaving no tombstone is the difference from prune. It appends
one line to `emit.err` recording a count and no payloads.

**Never automatic inside a dispatch path.** Prune runs from `orchestrate-doctor --prune`, from a
user-invoked `ccevent prune`, or from an opportunistic check at `ccd` startup that fires at most
once per 24 h, detached, after the pane is up. `ccw` never prunes.

**Uninstall.** `uninstall.sh` removes symlinks only and leaves `$CCT_TRACE_HOME` intact — data
outlives the tool. It prints the path and the `ccevent purge --all` command rather than deleting
anything itself.

### D9. Privacy, redaction and access control

Briefs are the highest-risk payload: `SKILL.md:269-291` prescribes a format containing repo paths,
constraints and DoD text, and a user may paste a credential into one. The source only truncates
(`tracer.py:156-158`, `request[:500]`) and does not redact.

**Redaction runs inside `ccevent` before the spool write (D7.1 step 2), so unredacted text never
reaches disk:**

- `scope` and `prompt_sent` store `brief_sha256`, `brief_bytes` and the first line only.
- Full brief text only when `CCT_TRACE_BRIEFS=1` is explicitly set.
- A deny-pattern scrub runs over every payload string **regardless of that setting**: GitHub token
  prefixes (`ghp_`, `github_pat_`, `gho_`, `ghu_`, `ghs_`, `ghr_`), OpenAI-style `sk-` keys, AWS
  `AKIA[0-9A-Z]{16}`, Slack `xox[baprs]-`, PEM private-key headers, HTTP authorization header
  values, and any 16+ character token immediately following `token`, `secret`, `password` or
  `api_key` (case-insensitive). Matches are replaced with a redaction marker.
- Redaction is recorded, not hidden: `payload.redactions` carries a count per pattern name, so a
  reader can tell scrubbing occurred without seeing what was scrubbed.
- Payloads over `CCT_PAYLOAD_MAX` are truncated with `payload_truncated:true` (D7.4).
- Local absolute paths are retained — the store is local-only, `0600`, and gitignored.

**Access control (D2 restated as policy):** `$CCT_TRACE_HOME` is `0700`; every file is `0600`;
`umask 077` is set before any create; `ccevent` refuses to write to a trace home it does not own;
`doctor` FAILs on any group- or world-readable path. The producer never opens a network listener.
If a secret does land in the store, `ccevent purge` (D8) is the remedy, documented alongside
redaction rather than presented as a substitute for it.

### D10. Viewer adapter — strictly read-only, and replaceable

**The contract is the spool and SQLite files plus the documented schema, not an API.** Any process
that can open SQLite read-only, or read NDJSON, is a valid viewer.

**Strictly read-only is a hard rule here, and it is a deliberate divergence from the source.** The
SSSF viewer is *mostly* read-only: `{ readonly: true }` for all trace queries (`server/db.ts:77`),
plus **a separate archive-state write** on its own lazily-opened writable connection
(`setArchived`, `server/db.ts:141-148`), updating the producer-declared reader-owned column at
`tracer.py:26`. **The target does not adopt that exception.** Rationale:

1. A writable reader connection can take `SQLITE_BUSY` locks against the producer's own flush,
   turning a viewer into a source of producer latency.
2. It makes "viewer absent" and "viewer present" observably different at the storage layer — which
   is exactly the property this design must guarantee is unobservable.
3. It creates a second writer to a store whose entire integrity argument is single-writer.

Rules for any reader:

- Open SQLite with `readonly: true` (`server/db.ts:77`) or NDJSON `O_RDONLY`. **Issue `SELECT`
  only. No `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `VACUUM`, and no second writable connection.**
- Never migrate. Probe optional columns with a cached `PRAGMA table_info`, as the source reader
  already does and documents (`server/db.ts:98-101`, `:65`, `:113-116`). Select named columns,
  never `SELECT *`.
- Poll `WHERE batch_id = ? AND rowid > ? ORDER BY rowid LIMIT n` (`server/db.ts:368-382`), then
  sort each page by `seq` (D6).
- Render `confidence='advisory'` distinctly from `deterministic`, and mark any batch carrying
  `spool_loss` rows or a `trace_loss` event as incomplete (D7.5).
- To get fresher data a reader may **invoke `ccevent flush` as a subprocess**, delegating the write
  to the producer. It must never write either store itself.

**Annotations live outside the event database.** If review state, tags, comments or ratings are
wanted later, they belong in a **separate optional store owned by the annotation tool** — e.g.
`$CCT_TRACE_HOME/annotations.db`, or a service — keyed by `batch_id`/`event_id` and joined at read
time. The producer neither creates, reads, migrates nor prunes it, and its absence is the normal
case. No `reviewed` or `archived` column is added to the event database; the source's
`sessions.archived` (`tracer.py:26`) is explicitly **not** ported.

Ship no viewer in Stages 1-4. `ccevent show <batch>` / `ccevent tail` (plain text, read-only) is
enough to prove the data is there.

Replaceability test: deleting every reader artefact must leave producer behaviour byte-identical.
That holds by construction — no producer code path references a reader.

### D11. Data flow, and why production survives with no viewer

```
              ── PRODUCER (the only writer) ──          ── CONSUMERS (read-only) ──

  ccd  ──┐                                  ┌───────────────┐
         ├─ lib/trace.sh trace_emit ────────┤ spool/*.jsonl │  (canonical, append-only, 0600)
  ccw  ──┤   CCT_TRACE gate · timeout 5     └───────┬───────┘
         │   || true · return 0     (ccevent emit)  │ ◄──────── reader C: jq / grep (O_RDONLY)
 orchestrator (SKILL.md) ── ccevent ────────────────┤
                                                    │ ccevent flush  (single writer, flock,
                                                    ▼                 offset committed after txn)
                                            ┌───────────────┐
                                            │   trace.db    │ ◄──────── reader A: readonly:true, SELECT only
                                            │  (derived,    │ ◄──────── reader B: sqlite3 -readonly
                                            │   WAL, 0600)  │ ◄──────── ccevent show / tail
                                            └───────────────┘
                                                    ▲
                                  annotations.db ───┘  (separate, optional, reader-owned,
                                                        joined at read time, never in trace.db)
```

Every arrow into a store originates from `ccevent`. Every consumer arrow points outward. There is
no ingest endpoint, no socket, no push — the property the source states outright
(`references/observability.md:141-143`).

The independence claim rests on six verifiable properties, each with a source precedent:

1. **No reader import, link or network call in the producer.** `ccevent` imports `sqlite3`, `json`,
   `os`, `fcntl`, `hashlib` and `secrets` only — the posture verified in the source, where `rg` for
   `visualizer`, `import.*apps`, `localhost:` and `http://` across all producer Python returns
   nothing (`tracer.py:10-15`).
2. **The producer creates both stores.** `O_CREAT` on the spool, and `CREATE TABLE IF NOT EXISTS`
   on every open (`tracer.py:17-92`, `:112`), mean the first `ccw` dispatch on a clean machine
   materialises everything — no install step, no reader present.
3. **Emission completes at the spool write (D7.1 step 3).** The durable record exists before SQLite
   is involved at all, so a permanently broken database costs zero events.
4. **Flow is one-directional and pull-based.** Consumers poll files; nothing is pushed to them.
5. **Readers are strictly read-only (D10)**, with no writable surface at all — no `archived`-style
   exception, no annotation column. A reader cannot hold a lock a producer waits on, cannot
   migrate, and cannot alter producer state by any path.
6. **Emission failure is isolated (D7.6).** Because no emit outcome can fail a dispatch, "no viewer
   installed", "viewer running", "viewer crashed mid-read" and "database deleted" are all
   indistinguishable to `ccw` and `ccd`. WAL keeps concurrent reading safe for the writer
   (`tracer.py:109-111`).

Stated as a falsifiable claim for the test suite: **with `bin/ccevent`, `lib/trace.sh` and the
entire trace home deleted, and with no reader ever installed, `ccw` and `ccd` must produce
byte-identical stdout, identical exit codes, and an identical sequence of `herdr` invocations.**
A1 and A2 in Part 5 test exactly that.
---

## Part 4 — Impact assessment

### Files added

| Path | Kind | Approx. size |
|---|---|---|
| `bin/ccevent` | python3, stdlib only — envelope, versioning, spool write, flush/replay, migrate, prune, purge, status, show, doctor | ~520 lines |
| `lib/trace.sh` | bash helper, non-blocking and failure-isolated, sourced like `lib/roles.sh` | ~55 lines |
| `tests/trace-emission.sh` | fake-`herdr` harness, mirrors `tests/pane-role-naming.sh` | ~110 lines |
| `tests/trace-isolation.sh` | dispatch continuity under every emitter failure mode | ~110 lines |
| `tests/trace-spool.sh` | replay, duplicates, ordering, overflow/loss accounting | ~120 lines |
| `tests/trace-migration.sh` | old reader/new db, new reader/old db, old spool/new producer | ~90 lines |
| `tests/run-all.sh` | runner; the bundle currently has none | ~25 lines |
| `docs/observability.md` | envelope, versions, migration contract, taxonomy, **strict** reader contract, loss semantics — modelled on `references/observability.md` | ~220 lines |

### Files changed

| Path | Change | Notes |
|---|---|---|
| `bin/ccw` | source `lib/trace.sh` beside `lib/roles.sh` (`:63-64`); emit at `:126-146`, `:212-250`, `:256-260`, `:262-271`, `:273-275`; suppress under `--dry-run` (`:152-176`). Emit-only — never flush, never prune | ~18 lines |
| `bin/ccd` | source helper (`:64-65`); emit at `:116-119`, `:185-197`, `:122-125`; detached post-startup `ccevent flush` and ≤24 h prune check | ~14 lines |
| `bin/orchestrate-doctor` | the D7.8 check table plus permissions, `schema_version`/`min_reader_version`, quarantine count — using existing `pass`/`warn`/`fail` (`:78-80`) and `check_on_path` (`:196-211`); add `--prune` | ~60 lines |
| `install.sh` | link `bin/ccevent` alongside `ccd`/`ccw` (`:225-227`); create `$CCT_TRACE_HOME` `0700`; the "seven symlinks" header comment (`:4`) must be corrected | ~10 lines |
| `uninstall.sh` | remove the symlink; **leave the store intact**, print its path and the `ccevent purge --all` command (D8) | ~6 lines |
| `.gitignore` | currently `.DS_Store` only; add `trace.db*`, `*.jsonl` spool patterns and `.herdr-team/` | 3 lines |
| `skills/orchestrate/SKILL.md` | emission steps at `:69`, `:75`, `:107`, `:205`, `:235`, `:259`, `:293`, `:354`, `:370`, `:411`, `:418`, `:451`; `ccevent` in the command reference (`:319-352`) | ~70 lines |
| `agents/orchestrator.md` | explicit `ccevent` carve-out in the "Bash is not a loophole" list, and in the allowed read-only command list — **blocking for advisory events** (F15) | ~8 lines |
| `README.md` | bundle contents (`:33`), doctor (`:245`), plus an observability section covering trust labels, loss and purge | ~40 lines |

### Operational and compatibility impact

- **Dependencies:** none added. `python3` is already required (`bin/ccw:178`, `bin/ccd:129`);
  `sqlite3`, `json`, `fcntl`, `hashlib`, `secrets` are stdlib.
- **Latency on the dispatch path:** one `python3` start plus one append per event, ~30-60 ms, hard
  capped at `timeout 5`. Five deterministic events add ~0.2-0.3 s to a dispatch that already waits
  up to 120 s for copilot (`bin/ccw:66`). **SQLite work is off this path entirely** (D7.2), so db
  contention cannot slow a dispatch at all.
- **Backwards compatibility:** `ccw`'s stdout contract (`bin/ccw:273-275`) and exit codes are
  unchanged; `--dry-run` stays side-effect free; `CCT_TRACE=0` restores exact current behaviour.
- **Disk:** ~20-40 events per batch; bounded by D7.4 caps and D8 retention. Worst case is the
  512 MB spool cap plus a comparable db.
- **Multi-writer:** many `ccw` processes append to the spool concurrently under `flock`; exactly
  one process writes SQLite at a time under `flush.lock`. WAL plus `busy_timeout=5000`
  (`tracer.py:109-111`, `references/observability.md:133-139`) covers readers during that write.
- **Data lifecycle:** the store survives uninstall and reinstall; only `ccevent purge` deletes
  irreversibly.

### Risks, in priority order

| Id | Risk | Severity | Mitigation |
|---|---|---|---|
| **R1** | Advisory events depend on LLM compliance; a batch missing `verify_result` is ambiguous | High | producer-derived `confidence` (D4); doctor/reader coverage reporting; convert to deterministic via Q3/S6 |
| **R2** | `bin/ccw:34` `set -euo pipefail` — any unguarded emit failure aborts a dispatch and strands a bare pane | High | D7.6 clause-by-clause guard; `tests/trace-isolation.sh` is gating |
| **R3** | `agents/orchestrator.md` forbids file-writing bash "no exceptions", blocking `ccevent` | High (blocking) | explicit carve-out in Stage 4; never left to interpretation |
| **R4** | Secrets or proprietary code captured in brief payloads | High | pre-write redaction, hash-by-default, `0600`/`0700`, `ccevent purge` (D9, D8) |
| **R5** | Silent data loss under overflow would make the trace untrustworthy | High | loss is counted, projected to `spool_loss`, emitted as `trace_loss`, and surfaced by doctor; lifecycle events never dropped ahead of `log` (D7.5) |
| **R6** | Replay produces duplicate rows, inflating counts | High | content-derived `event_id` + `INSERT OR IGNORE` + offset committed after txn (D6, D7.2) |
| **R7** | A reader that writes takes locks against the producer or corrupts state | High | strictly read-only contract, no `reviewed`/`archived` column, annotations in a separate store (D10) |
| **R8** | Readers infer causal order from `rowid` or wall clock and render events wrongly | Medium | explicit three-field ordering table and stated non-guarantees (D6); documented in `docs/observability.md` |
| **R9** | Spool/db divergence or a corrupt db | Medium | spool is canonical and db is rebuildable; corrupt db is renamed and rebuilt automatically (D7.3) |
| **R10** | Schema drift between producer and third-party readers | Medium | `meta.schema_version`/`min_reader_version`, `event_version` per record, additive-only rules (D3), precedent `tracer.py:94-100`, reader tolerance `shared/types.ts:196-199` |
| **R11** | Store on a non-POSIX-locking mount (`/mnt/c` under WSL, NFS) breaks WAL and `flock` | Medium | default under `$HOME`; doctor asserts WAL engaged and `flock` works, FAILs otherwise |
| **R12** | Unbounded growth (the source's unfixed gap) | Medium | D8 retention by age/count/size + doctor WARN |
| **R13** | Missing `CCT_BATCH_ID` orphans events | Medium | derived `tab-<tab_id>` fallback (D5); an event is never dropped for want of a batch |
| **R14** | Never-flushed backlog leaves the db permanently empty while spool grows | Medium | flush triggers in `ccd`, every read command and doctor; doctor WARNs when last flush > 24 h |
| **R15** | Instrumentation bloats `ccw`, currently a tight readable script | Low | all logic in `ccevent`; `ccw` gains one-line calls only |
| **R16** | Untracked, unreferenced `tests/` with no CI means new tests may never run | Low | `tests/run-all.sh` in S3; doctor mentions it |

### Staged rollout and dependency order

| Stage | Content | Depends on | Independently verifiable |
|---|---|---|---|
| **S1** | `bin/ccevent` — envelope + `event_version`/`schema_version` + spool write + `flush` replay + `migrate` + `status`; `lib/trace.sh`. No call sites. | — | Yes: emit/flush/re-flush into a tmp home, assert row counts and idempotency |
| **S2** | Deterministic emission in `ccw`/`ccd`; D7.6 guard; `CCT_TRACE=0`; detached flush in `ccd` | S1 | Yes: fake-herdr harness, isolation matrix |
| **S3** | `install.sh`, `uninstall.sh`, `orchestrate-doctor` checks + `--prune`, `.gitignore`, `README.md`, `docs/observability.md`, `tests/run-all.sh` | S2 | Yes: doctor exit codes, permission assertions |
| **S4** | Advisory emission — `SKILL.md` steps + `agents/orchestrator.md` carve-out (R3) | S1; S3 for docs | Partly: run a batch, inspect coverage by `confidence` |
| **S5** | `ccevent prune`/`purge` + retention defaults + archive | S1; S3 for the doctor hook | Yes: age/count/size eviction, tombstones, purge leaves nothing |
| **S6** | Optional `bin/ccp` wrapping `herdr agent prompt`/`wait`/`get`, converting `prompt_sent` and `agent_settled` from advisory to deterministic | S4 + measured S4 compliance | Yes |
| **S7** | Reader adapter beyond `show`/`tail`; optional separate `annotations.db` tool | S1 | Yes: read-only conformance suite |

Ship **S1-S3 as one increment**: a complete, guaranteed dispatch trace that is versioned, bounded,
loss-accounted and viewer-free. S4 adds delivery semantics. S5 must land before any long-lived
deployment. S6 is a response to measured advisory drift, not a speculative build. S7 is last, and
its absence is the normal state.

Sizing: S1 ≈ 575 lines, S2 ≈ 32, S3 ≈ 340 (mostly docs and tests), S4 ≈ 78 doc lines, S5 ≈ 120,
S6 ≈ 150, S7 ≈ variable.

### Test strategy

Follow the existing harness pattern in `tests/pane-role-naming.sh:17-46` — a fake `herdr` on
`PATH` appending every invocation to a log, then `grep -Fxq` assertions — with `$CCT_TRACE_HOME`
pointed at a temp dir and a `trap` cleanup.

**Viewer absence and producer independence**

| Id | Test | Asserts |
|---|---|---|
| T1 | emit into an empty tmp home, then `flush` | spool file created `0600`, db created, schema present, one `events` row, `meta.schema_version` set |
| T2 | full `ccw` run with no reader ever installed | dispatch succeeds; spool has all deterministic events; no listening socket opened by `ccevent` (verified by `ss`/strace-free check: no network import) |
| T3 | **byte-identity** — capture `ccw` stdout, exit code and fake-herdr log with tracing on, then with `CCT_TRACE=0`, then with the whole trace home and `ccevent` deleted | all three identical |
| T4 | delete `trace.db` mid-batch, continue dispatching, then `flush` | no error surfaced; db rebuilt from spool; no events lost |

**Strict read-only access**

| Id | Test | Asserts |
|---|---|---|
| T5 | reader conformance — open `readonly:true`, attempt `INSERT`/`UPDATE`/`ALTER`/`VACUUM` | every write rejected by SQLite |
| T6 | schema audit | no `reviewed`, `archived` or any reader-writable column exists in the event db |
| T7 | reader holds an open read connection across a flush | reader sees new rows without restart; flush is not blocked |
| T8 | `annotations.db` absent | every reader path still works; producer never references it |

**Duplicate, replay and ordering**

| Id | Test | Asserts |
|---|---|---|
| T9 | `flush` the same spool three times | row count unchanged after the first; `event_id` stable |
| T10 | kill `flush` between txn commit and offset write, then re-run | no duplicates, no loss (offset-after-commit invariant) |
| T11 | same `--key` emitted twice | exactly one row (partial unique index) |
| T12 | 20 concurrent emits + concurrent flush | 20 spool lines, 20 rows, no `database is locked`, `seq` unique per batch |
| T13 | ordering semantics | `seq` is contiguous per batch; `rowid` paging returns each event exactly once; a late-flushed event has a higher `rowid` but its original `seq` |

**Trust labeling, redaction, loss, migration, continuity**

| Id | Test | Asserts |
|---|---|---|
| T14 | trust labels | `ccw`-sourced events are `deterministic`; `--source orchestrator` yields `advisory`; a caller-supplied `--confidence` is ignored |
| T15 | redaction | a payload containing a GitHub-token-shaped string is stored redacted **in the spool file itself**; `payload.redactions` counts it; brief stored as hash unless `CCT_TRACE_BRIEFS=1` |
| T16 | permissions | home `0700`, spool/db/wal/shm `0600` under a permissive umask; doctor FAILs when a file is chmod `0644` |
| T17 | spool overflow | with a 4 KB cap, excess events are dropped, `.dropped` increments, `spool_loss` populated after flush, a `trace_loss` event appears, and a `log` event is dropped before a lifecycle event |
| T18 | loss observability | `ccevent status --json` and `orchestrate-doctor` both report backlog and dropped counts non-zero |
| T19 | failed-emission continuity — trace home unwritable / `ccevent` absent / emitter hung past `timeout` / disk full | `ccw` exits 0 in all four, `agent start` still logged, stdout unchanged |
| T20 | failure-path event | a failing `herdr agent start` yields `dispatch_fail` **and** still closes the pane (`bin/ccw:265-269`) |
| T21 | migration — old reader vs new db | a reader selecting only v1 columns works against `schema_version` 3 |
| T22 | migration — new reader vs old db | absent columns read as null, no exception |
| T23 | migration — old spool vs new producer | v1 lines upgrade in memory; a line with a future `event_version` is quarantined and counted, never dropped silently |
| T24 | `--dry-run` | no spool file, no db, exit 0 |

Existing test discovery: `tests/pane-role-naming.sh` is the only test, invoked directly as
`bash tests/pane-role-naming.sh` (self-contained, `set -euo pipefail`, tmp dir + `trap` cleanup).
No CI, no runner. `tests/run-all.sh` lands in S3.

---

## Part 5 — Assumptions, unresolved decisions, acceptance criteria

### Assumptions

1. `herdr` 0.8.0 exposes no hook or callback mechanism for agent state transitions. Nothing in
   `SKILL.md:319-352` (the verified command reference) suggests one. **Unverified against herdr's
   own source** — if hooks exist, they would make F13's supervise events deterministic without S6.
2. `python3` ≥ 3.8 with `sqlite3` and `fcntl` is present wherever the bundle runs — implied by
   `bin/ccw:178-196` and `bin/ccd:129-134`.
3. `$CCT_TRACE_HOME` sits on a local POSIX filesystem supporting `flock` and WAL. Doctor asserts
   this rather than assuming it (R11).
4. The in-flight uncommitted changes to `ccw`, `ccd` and `SKILL.md` do not move the emission points
   in F12/F13. Line citations are against the working tree, not `HEAD`.
5. Multiple concurrent orchestrators on one machine are possible; one shared store partitioned by
   `batch_id` is sufficient.
6. A machine-crash window of a few unflushed, unsynced spool events is acceptable (D7.1). If it is
   not, `fsync` per emit is the knob, at a latency cost on the dispatch path.

### Unresolved decisions

| Id | Question | Options |
|---|---|---|
| **Q1** | Store location — single `$HOME` store vs per-repo | O1a `$HOME` (proposed; keeps a cross-repo batch whole) · O1b per-repo, matching `sssf.config.yaml:36` · O1c `$HOME` with a per-repo override |
| **Q2** | Do advisory events ship in v1, or does S1-S3 stand alone? | O2a deterministic-only first, measure the gap · O2b ship both together |
| **Q3** | Is `bin/ccp` (S6) worth the extra command surface, given `herdr agent prompt` is documented directly at `SKILL.md:263-265` and in user muscle memory? | O3a build it · O3b keep advisory and accept the gap · O3c defer until compliance is measured |
| **Q4** | Reader strategy | O4a SSSF visualizer via a schema shim (fast, but couples to `f_id`/`phase_id` naming **and** would have to give up its `setArchived` write, `server/db.ts:141-148`) · O4b `ccevent show`/`tail` only · O4c new read-only UI later |
| **Q5** | Should a failed emit ever be visible to the user? | O5a always silent + `emit.err` + doctor WARN (proposed) · O5b one-line stderr note on first failure per invocation |
| **Q6** | Retention defaults — age, count, size, or all three (proposed)? | O6a age only · O6b count only · O6c all three, first-to-trigger wins |
| **Q7** | Is capturing brief text (even opt-in) acceptable given work happens in corporate repos? | O7a hash-only, remove `CCT_TRACE_BRIEFS` entirely · O7b opt-in as proposed |
| **Q8** | Flush trigger policy | O8a opportunistic only (proposed: `ccd`, read commands, doctor) · O8b add a `systemd --user` timer / launchd agent · O8c flush inside `ccw` after the pane is up (rejected: reintroduces db work on the dispatch path) |
| **Q9** | Drop policy under overflow | O9a drop `log`-class oldest-first, never lifecycle (proposed) · O9b drop everything oldest-first · O9c block the emitter (rejected: violates non-blocking) |
| **Q10** | Does `event_version` need per-type versioning, or is one global record version enough? | O10a one global version (proposed) · O10b per-type payload versions |
| **Q11** | Where do annotations live if they are ever wanted? | O11a separate `annotations.db` beside the store (proposed) · O11b a service · O11c never build them |

### Acceptance criteria for a future implementation brief

**A1 — Producer independence and viewer absence**

- A1-1 `bin/ccevent` imports no network module and references no reader; `rg -n 'socket|http|urllib|requests|localhost|fetch' bin/ccevent` returns nothing.
- A1-2 On a machine where no reader has ever been installed, one `ccw` dispatch creates the trace home, the spool file and ≥ 5 spooled events; a subsequent `ccevent flush` creates the db and ≥ 5 rows.
- A1-3 Deleting the db mid-batch, dispatching again, then flushing, rebuilds every row from the spool with no error on stdout and no loss.
- A1-4 Deleting the entire trace home mid-batch recreates it on the next emit; the dispatch is unaffected.
- A1-5 With a reader holding an open read connection, a dispatch and a flush both complete, and rows become visible to that reader without restarting it.
- A1-6 Removing every reader artefact leaves `bin/ccw` and `bin/ccd` behaviour byte-identical.

**A2 — Failed-emission continuity (nothing may fail a dispatch)**

- A2-1 Trace home unwritable (`chmod 000`) → `ccw <name> --role build --cwd .` exits 0 and `herdr agent start` still appears in the fake-herdr log.
- A2-2 `bin/ccevent` absent from PATH → same result.
- A2-3 Emitter hung → dispatch proceeds within `CCT_EMIT_TIMEOUT`, the emit is abandoned and counted.
- A2-4 Disk full → same result; the drop is counted with `reason='unwritable'`.
- A2-5 Db corrupt or held by another writer → dispatch unaffected, because emit never touches SQLite (D7.2).
- A2-6 `ccw` stdout and exit code on success match the pre-change output exactly.
- A2-7 `CCT_TRACE=0` creates no files and produces an identical `herdr` invocation sequence.
- A2-8 `--dry-run` emits nothing and exits 0.

**A3 — Strict read-only access**

- A3-1 The event db contains **no** reader-writable column: `reviewed`, `archived` and equivalents are absent (schema audit).
- A3-2 A reader opened `readonly:true` is rejected by SQLite on `INSERT`, `UPDATE`, `DELETE`, `ALTER` and `VACUUM`.
- A3-3 `docs/observability.md` states the strict read-only rule, states that the SSSF viewer is only *mostly* read-only (`server/db.ts:77` vs `setArchived`, `server/db.ts:141-148`), and states that the exception is not ported.
- A3-4 No producer code path reads or writes `annotations.db`, and every reader path works when it is absent.
- A3-5 A reader never migrates: with `schema_version` ahead of the reader, no DDL is issued by the reader process.

**A4 — Duplicate and replay handling**

- A4-1 Flushing the same spool three times leaves the row count unchanged after the first.
- A4-2 `event_id` for a given spool line is identical across re-flush and full rebuild.
- A4-3 Killing flush between commit and offset write, then re-running, produces no duplicates and no loss.
- A4-4 A repeated `idem_key` within a batch yields exactly one row.
- A4-5 A full `--rebuild` from spool reproduces the db byte-equivalently in row content.

**A5 — Deterministic ordering semantics**

- A5-1 `seq` is unique per batch across concurrent emitters, and contiguous when no loss occurred.
- A5-2 `rowid` paging returns each event exactly once and never skips.
- A5-3 An event flushed late has a higher `rowid` than one emitted after it, while retaining its original `seq` — proving `rowid` is a cursor, not a clock.
- A5-4 `docs/observability.md` documents the three-field table and the four explicit non-guarantees from D6.

**A6 — Trust labeling**

- A6-1 Every event row has non-null `batch_id`, `type`, `source`, `confidence`, `event_version`, `emitted_at` and `seq`.
- A6-2 `confidence` is derived inside `ccevent` from `--source`; a caller-supplied confidence value is ignored.
- A6-3 `ccw`/`ccd` events are `deterministic`; orchestrator events are `advisory`.
- A6-4 A reader can report, per batch, which advisory event types are absent, and `ccevent status` exposes the same.

**A7 — Redaction and access control**

- A7-1 A payload containing a GitHub-token-shaped string is redacted **in the spool file on disk**, not only in the db.
- A7-2 `payload.redactions` records a count per pattern name.
- A7-3 Brief text is stored as `brief_sha256` + `brief_bytes` + first line unless `CCT_TRACE_BRIEFS=1`.
- A7-4 Trace home is `0700`; spool, db, `-wal`, `-shm` and archives are `0600`, under a permissive inherited umask.
- A7-5 `orchestrate-doctor` FAILs when any store path is group- or world-readable.
- A7-6 `ccevent purge --batch <id> --yes` leaves no rows, spool, offset, counter, archive or tombstone for that batch.

**A8 — Spool overflow and loss observability**

- A8-1 With caps lowered, excess events are dropped rather than blocking, and the dispatch still exits 0.
- A8-2 Each drop increments a counter carrying `reason`, `first_at` and `last_at`.
- A8-3 Flush projects counters into `spool_loss`, and a `trace_loss` event appears in the stream.
- A8-4 A `log`-class event is dropped before any lifecycle event under the same pressure.
- A8-5 `ccevent status --json` and `orchestrate-doctor` both report non-zero backlog and dropped counts; loss is never inferable only by absence.
- A8-6 A reader marks any batch with loss as incomplete and computes no completeness metric over it.

**A9 — Versioning and migration**

- A9-1 `meta` carries `schema_version`, `min_reader_version` and `producer_version`; every event row and NDJSON line carries `event_version`.
- A9-2 Old reader vs new db: a reader selecting only v1 columns works against a later `schema_version` while `min_reader_version` permits it.
- A9-3 New reader vs old db: absent columns read as null, no exception.
- A9-4 Old spool vs new producer: v1 lines upgrade in memory during flush.
- A9-5 A line with a future `event_version` is quarantined and counted, never silently dropped.
- A9-6 An unparseable line is quarantined, counted as `corrupt_line`, and does not block the rest of the flush.
- A9-7 `ccevent migrate` issues additive DDL only; no test migration drops, renames or retypes a column.

**A10 — Lifecycle coverage**

- A10-1 `agents/orchestrator.md` names `ccevent` as permitted and no longer contradicts it.
- A10-2 A successful `ccw` dispatch emits `dispatch_start`, `pane_acquired`, `pane_labeled`, `agent_started`, `dispatch_ok`.
- A10-3 A failing `herdr agent start` emits `dispatch_fail` **and** still closes the pane (`bin/ccw:265-269` behaviour preserved).
- A10-4 `ccd` emits `orchestrator_started` on all three paths (`bin/ccd:116-119`, `:185-197`, `:122-125`).
- A10-5 A full orchestrate batch produces a queryable batch with agents, verify result and cleanup, and a reader can state which advisory events are missing.
- A10-6 A batch with no `batch_end` and no event for `CCT_BATCH_STALE` reports `abandoned`; nothing writes a fabricated outcome.

**A11 — Retention and documentation**

- A11-1 `ccevent prune` evicts by age, count and size; only terminal, fully-flushed batches are eligible; a `running` batch is never pruned.
- A11-2 Prune leaves a tombstone and the `spool_loss` row; purge leaves neither.
- A11-3 No prune or purge ever runs from `bin/ccw`.
- A11-4 `uninstall.sh` leaves the store intact and prints the purge command.
- A11-5 `docs/observability.md` documents every table, column, event type, version field, ordering guarantee, loss semantic and the reader contract.
- A11-6 `orchestrate-doctor` reports store health and still exits 0 on a healthy install.
- A11-7 `install.sh --dry-run` lists the `ccevent` symlink; the "seven symlinks" comment (`install.sh:4`) is corrected.
- A11-8 `.gitignore` prevents any spool or db file from being committed.
- A11-9 T1-T24 pass via `bash tests/run-all.sh`.
