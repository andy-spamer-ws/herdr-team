---
name: orchestrate
description: >
  Run delivery work as an orchestrator: scope it, route it to the cheapest
  substrate that works, name it, pick a tier, dispatch it with `ccw` into a
  named herdr pane, supervise it, verify it against the DoD, correct it once,
  clean up, report. Use when you are holding a unit of delivery work that
  someone else should execute — a fix, a feature, a batch of issues, a
  migration, a diagnosis — and you need to decide subagent vs pane vs tab vs
  factory, and at which model tier. Not for answering questions, reading code
  back, or single trivial edits you were asked to make inline.
author: Andy Spamer
---

# Orchestrate

You decide what the work is, who does it, and whether it came back good. You
do not do it.

The lifecycle, in order: **Scope → Route → Name → Tier → Dispatch → Supervise
→ Verify → Correct once → Clean up → Report.**

---

## When to use / when not to

| Use it | Do not use it |
|--------|---------------|
| Any unit of delivery work: edit, build, test, migrate, refactor, commit | Answering a question inline |
| A batch of related issues that needs a dependency order | Reading code back to the user |
| Two or more independent writers that could run at once | A decision the user has to make first |
| Work that needs a verifier who never saw the worker's report | Research you can do yourself in three reads |
| Long-lived services that must survive the current task | Anything where the brief is not yet writable |

If you cannot write DONE WHEN, you are not ready to dispatch. Scope more
first. A vague brief produces vague work, and that is the failure mode this
skill exists to prevent.

---

## 1. Scope

Read enough to write the brief: which files change, what done looks like, what
constraint the worker cannot discover on their own. Nothing more. Reading
past that point is you starting to do the work.

## 2. Route — cheapest substrate that works

| Situation | Substrate |
|-----------|-----------|
| Read-only research or review | Agent-tool subagent. No pane. |
| Single writer, sequential | Named pane in the current tab. |
| Two or more concurrent writers | **New named tab**, one herdr worktree plus one pane per writer. |
| Different repo, or a long-lived service | New tab, name prefixed `svc-`. |
| Acceptance criterion writable up front **and** repo is factory-stamped | `factory run <workflow>` |

**The factory test is one question: can you write the acceptance criterion
before the work starts?** Yes plus a stamped repo means factory. No means a
named claude pane.

Run `factory doctor`, the read-only readiness check, to verify whether a repo is factory-stamped.

## 3. Name

Every work item carries a unique name.

- **Tab = the batch.** `issue-89-90`
- **Agent = the task.** `diagnose-89`, `fix-90`
- **Worktree label matches the agent name.**

Pane ids (`1-3`, `2-1`) are **legacy**. They compact when panes close. Never
use a pane id when talking to the user — use the agent name.

## 4. Tier — the model is the dial, effort is a deviation

| Tier | Flags ccw applies | Use for |
|------|-------------------|---------|
| `mechanical` | `--model haiku` (no `--effort` — the model rejects it) | Rename, move, delete, mechanical edits |
| `build` | `--model sonnet` (already defaults to high) | Write the code, write the tests |
| `diagnose` | `--model opus` (already defaults to high) | Find out why, read across modules |
| `hard` | `--model opus --effort xhigh` | Design, tricky concurrency, migrations |

Bias **up** when the right tier is unclear. `max` and `ultracode` are not in
the vocabulary.

## 5. Dispatch — `ccw` is THE command

```
ccw <name> --tier <mechanical|build|diagnose|hard> --cwd <path> \
    [--split right|down] [--tab ID] [--new-tab LABEL] \
    [--focus|--no-focus] [--dry-run] [-- extra claude args]
```

`ccw` requires the name and `--tier`; either missing, or an unknown tier,
exits non-zero with usage. It always appends the SR addendum system prompt
(override with `CCW_ADDENDUM`; a warning to stderr and it continues if
unreadable) and always adds `--dangerously-skip-permissions`.

What it runs:

```bash
herdr agent start <name> --cwd <path> [--tab ID] [--split right|down] [--focus|--no-focus] \
  -- claude --model <haiku|sonnet|opus> [--effort xhigh] \
     --append-system-prompt "<addendum>" --dangerously-skip-permissions [extra]
```

`--effort xhigh` appears for the `hard` tier only. It is never added for
`mechanical`. With `--new-tab LABEL`, `ccw` first runs
`herdr tab create --label LABEL --cwd <path> --no-focus`, reads the new tab id
from the JSON, and passes it as `--tab`. `--dry-run` prints the exact argv and
exits 0 without launching — use it whenever you are unsure what a flag will do.
Dry-run elides the addendum body, printing
`--append-system-prompt <addendum: 6.0K from /path/to/sr_opus_5_system_prompt.md>`
in its place; real launches pass the full text. Every other token is identical.

Concrete shapes:

```bash
# single writer, pane in this tab
ccw fix-90 --tier build --cwd /path/to/repo --split right --no-focus

# batch of two concurrent writers in their own tab and worktrees
herdr worktree create --cwd /path/to/repo --branch fix/89 --label diagnose-89 --no-focus
ccw diagnose-89 --tier diagnose --cwd /path/to/wt-89 --new-tab issue-89-90 --no-focus
ccw fix-90     --tier build     --cwd /path/to/wt-90 --tab <tab-id> --split down --no-focus

# long-lived service, never auto-closed
ccw svc-api --tier mechanical --cwd /path/to/repo --new-tab svc-api --no-focus
```

Deliver the brief with `herdr agent send <name> "<brief>"` then
`herdr pane send-keys <pane_id> Enter`. `send-keys` takes a pane id
positionally, never an agent name — get the id first with
`herdr agent get <name>` and read `result.agent.pane_id`.

### Brief format

Send exactly this shape. No preamble.

```
TASK: <one sentence, imperative>

CONTEXT:
- <repo / branch / cwd>
- <the 2-5 files that matter, with paths>
- <constraint the worker cannot discover on their own>

DO:
1. <concrete step>
2. <concrete step>

DONE WHEN:
- <observable, checkable condition>
- <test that must pass, command included>

DO NOT:
- <out of scope things you predict they will drift into>
```

## 6. Supervise

Never send input to a pane whose `agent_status` is `working` or `blocked`.
Block properly instead:

```bash
herdr agent wait <name> --status idle --timeout 600000
herdr agent read <name> --source recent --lines 80
```

Bound every read with `--lines`. When three or more tasks are in flight,
sketch the dependency order before dispatching anything and hold the merge
order yourself. Workers never talk to each other; blockers come to you.

### Verified command reference (herdr 0.7.3)

```
herdr tab create --label <LABEL> --cwd <PATH> --no-focus     -> result.tab.tab_id
herdr tab list                                               -> result.tabs[]
herdr agent list                                             -> result.agents[]
herdr agent get <name>                                       -> result.agent.pane_id, result.agent.agent_status
herdr agent send <name> "<text>"
herdr agent wait <name> --status idle --timeout <ms>
herdr agent read <name> --source recent --lines <N>          -> result.read.text
herdr pane send-keys <pane_id> Enter
herdr pane list --workspace <workspace_id>                   -> result.panes[]
herdr pane close <pane_id>
```

## 7. Verify

**A verifier session receives the DoD verbatim and never sees the worker's
report.** That is the point — a verifier that has read the worker's summary is
grading the summary, not the code.

Floor: you still read the changed files yourself whenever a protected path or
an interface is touched.

## 8. Correct once

One correction, sent back to the **same** pane. If it misses again, escalate to
the user. Twice missed means the brief was wrong, not the worker.

## 9. Clean up

A pane is closable when `herdr agent get <name>` reports `agent_status`
`idle` or `done`. Do not call `process-info` on a claude worker pane — the
claude REPL is always a foreground process there, so the "no foreground
process" test can never pass, and `process-info` prints the pane's full
argv, which for a `ccw`-launched worker includes the entire addendum system
prompt twice, flooding your context. Reserve `process-info` for panes
running a non-claude long-running command.

```bash
herdr agent get <name>
herdr pane close <pane_id>
```

Closing every agent pane in a tab leaves the tab alive with one bare shell
pane. Find and close that leftover too:

```bash
herdr pane list --workspace <workspace_id>
herdr pane close <pane_id>
```

`svc-` panes never auto-close. Workers never daemonize — long-lived processes
are started by you, in named `svc-` panes, with a note recording what the
service is pinned to (branch, commit, port, config).

## 10. Report

Tell the user what was delegated, under which agent name and tab, and what the
verdict was. Names, not pane ids.

---

## Context discipline

You keep only:

- the dependency graph and merge order
- the briefs you wrote
- the user's open decisions
- enough code shape to write the next brief

Everything else delegates and returns a verdict. Never dump the environment —
it leaks tokens for nothing. Bound every pane read with `--lines`. When
context runs hot, use the **handoff** skill rather than compacting mid-batch.
