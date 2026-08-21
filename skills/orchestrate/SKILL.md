---
name: orchestrate
description: >
  Run delivery work as an orchestrator: scope it, route it to the cheapest
  substrate that works, name it, pick a role, dispatch it with `ccw` into a
  named herdr pane, supervise it, verify it against the DoD, correct it once,
  clean up, report. Use when you are holding a unit of delivery work that
  someone else should execute — a fix, a feature, a batch of issues, a
  migration, a diagnosis — and you need to decide subagent vs pane vs tab vs
  factory, and at which model role. Not for answering questions, reading code
  back, or single trivial edits you were asked to make inline.
author: Andy Spamer
---

# Orchestrate

You decide what the work is, who does it, and whether it came back good. You
do not do it.

The lifecycle, in order: **Scope → Space → Route → Name → Role → Dispatch →
Supervise → Verify → Review (optional) → Correct once → Clean up → Report.**

Workers are GitHub Copilot CLI sessions in herdr panes. This skill is written
against **herdr 0.8.0**, where `herdr agent start` takes `--kind` and `--pane`
and never creates layout of its own, and where herdr's own hierarchy is
**session → workspace → tab → pane**.

### The five topology rules

1. Every `/orchestrate` invocation opens exactly **one new herdr workspace**,
   named for the goal, and does all its work inside it.
2. Every task, subagent, verifier, reviewer and worker for that goal is a
   **pane in that workspace's default tab**, renamed to describe the batch.
3. Services may use **separate tabs**, but always inside the same workspace —
   never a workspace or session of their own.
4. All code-producing work runs against a **new git worktree**, never the
   checkout the orchestrator itself is sitting in.
5. Every service tab launched is reported into the **workspace's status bar**
   via `herdr workspace report-metadata`, so its tab name stays visible without
   you having to keep saying it.

These are functional, not stylistic: they are how the user watching the herdr
UI finds the whole batch — worker, verifier, reviewer, and any services — in
one place, without hunting across tabs or workspaces.

---

## When to use / when not to

| Use it | Do not use it |
|--------|---------------|
| Any unit of delivery work: edit, build, test, migrate, refactor, commit | Answering a question inline |
| A batch of related issues that needs a dependency order | Reading code back to the user |
| Two or more independent writers that could run at once, in one workspace | A decision the user has to make first |
| Work that needs a verifier who never saw the worker's report | Research you can do yourself in three reads |
| Work that has passed its DoD and is about to become a PR | A change that has not been verified yet |
| Long-lived services that must survive the current task | Anything where the brief is not yet writable |

If you cannot write DONE WHEN, you are not ready to dispatch. Scope more
first. A vague brief produces vague work, and that is the failure mode this
skill exists to prevent.

---

## 1. Scope

Read enough to write the brief: which files change, what done looks like, what
constraint the worker cannot discover on their own. Nothing more. Reading
past that point is you starting to do the work.

## 2. Space — one workspace per invocation

Open the workspace before you dispatch anything else:

```bash
herdr workspace create --label <goal-slug> --cwd <repo-path> --no-focus
# -> result.workspace.workspace_id
#    result.tab.tab_id        (the default tab)
#    result.root_pane.pane_id (its first pane)
herdr tab rename <tab_id> "<meaningful batch name>"
```

That default tab, renamed, is where every task, subagent, verifier, reviewer
and worker for this goal lives, each as its own pane. There is no paneless
exception once the workspace exists — read-only research and review get a
pane there too, at the `analyse` or `review` role.

Because `herdr tab create` and `herdr pane split --current` without an
explicit target default to the **calling pane's own workspace**, `ccw`'s
`--tab <ID>` form is the one to reach for from here on — it addresses the
target tab directly, so it lands correctly regardless of which workspace the
orchestrator's own pane happens to sit in. `ccw --new-tab` has no `--workspace`
flag, so use it only when the orchestrator's own pane is already inside the
goal workspace; otherwise create the service tab directly (see Dispatch,
below).

Every code-producing worker gets a new git worktree, never the checkout the
orchestrator itself is sitting in — including a lone, sequential writer.
Services keep their own tab in this same workspace, prefixed `svc-`, and their
tab name gets surfaced through `herdr workspace report-metadata` (see
Dispatch). Close the workspace only once every pane in it is idle or done and
the batch has been reported.

## 3. Route — cheapest substrate that works

| Situation | Substrate |
|-----------|-----------|
| Read-only research or review, once the goal workspace exists | Pane in this goal's default tab, `analyse` or `review` role. |
| Single writer | Pane in this goal's default tab, on its own new worktree. |
| Two or more concurrent writers | Same default tab, one pane and one new worktree each. |
| Long-lived service | New tab in the **same** workspace, prefixed `svc-`. |
| Acceptance criterion writable up front **and** repo is factory-stamped | `factory run <workflow>` |

**The factory test is one question: can you write the acceptance criterion
before the work starts?** Yes plus a stamped repo means factory. No means a
named copilot pane.

Run `factory doctor`, the read-only readiness check, to verify whether a repo is factory-stamped.

## 4. Name

Every work item carries a unique name.

- **Workspace = the goal.** `issue-89-90`
- **Default tab = the batch**, renamed to match — every delivery agent for
  this goal is a pane in it.
- **Agent = the task.** `analyse-89`, `fix-90`
- **Worktree label matches the agent name.**
- **Service tab = `svc-<name>`**, still inside the goal workspace.

herdr requires agent names to match `[a-z][a-z0-9_-]{0,31}` and be unique among
live agents. `ccw` rejects anything else before it touches herdr.

Pane ids (`w16:p4`) are an implementation detail. Never use one when talking to
the user — use the agent name. Agent commands accept either.

## 5. Role — the model is the dial, effort is a deviation

| Role | Model `ccw` applies | Use for |
|------|---------------------|---------|
| `mechanical` | `gpt-5.6-luna --effort low` | Rename, move, delete, mechanical edits |
| `build` | `claude-sonnet-5 --effort medium` | Write the code, write the tests |
| `verify` | `gpt-5.6-terra --effort medium` | Run the DoD, read the diff, pass/fail |
| `review` | `claude-opus-5 --effort xhigh` | Adversarial pre-PR review: find what the DoD never named |
| `analyse` | `claude-opus-5 --effort xhigh` | Find out why, read across modules |
| `hard` | `claude-opus-5 --effort max --context long_context` | Design, tricky concurrency, migrations |
| `orchestrator` | `gpt-5.6-sol --effort high --context long_context` | What `ccd` runs you as |

Bias **up** when the right role is unclear, but know what it costs: `hard` and
`orchestrator` are roughly 25x the per-token price of `mechanical`, and
`long_context` roughly doubles the rate again on the OpenAI models. A herd where
the expensive roles do the typing is the failure mode that makes this whole
pattern lose money.

The mapping lives in `lib/roles.sh` in the bundle. Do not pass `--model`
yourself; change the role.

## 6. Dispatch — `ccw` is THE command

```
ccw <name> --role <mechanical|build|verify|review|analyse|hard|orchestrator> --cwd <path> \
    [--split right|down] [--tab ID] [--new-tab LABEL] \
    [--focus|--no-focus] [--dry-run] [-- extra copilot args]
```

`ccw` requires the name and `--role`; either missing, or an unknown role,
exits non-zero with usage. `--tier` is accepted as an alias for `--role`.
Workers always get `--allow-all`.

What it runs, in two steps, because herdr 0.8.0 `agent start` cannot create a
pane:

```bash
# 1. acquire a pane — one of:
herdr pane split --current --direction right --cwd <path> --no-focus   # default
herdr pane split --pane <first pane of TAB> --direction down --cwd <path> --no-focus  # --tab
herdr tab create --label LABEL --cwd <path> --no-focus                 # --new-tab

# 2. put copilot in it
herdr agent start <name> --kind copilot --pane <pane-id> --timeout 120000 \
  -- --model <model> --effort <level> [--context long_context] --allow-all
```

If `agent start` fails, `ccw` closes the pane it created rather than leaving a
bare shell behind. `--dry-run` prints both steps and exits 0 without launching —
use it whenever you are unsure what a flag will do.

There is **no addendum flag**. Copilot has no `--append-system-prompt`; the SR
communication addendum is installed once into the Copilot instructions file by
`install.sh` and applies to every worker automatically.

`ccw` needs `HERDR_PANE_ID` set unless you pass `--tab` or `--new-tab`, because
the default placement splits the pane you are in — and that default placement
never targets the goal workspace's default tab reliably, so **do not use
`ccw` with no `--tab`/`--new-tab` for this skill's work.** Address every pane
by the tab id from Space, above.

### Every delivery agent — same workspace, same default tab

One worktree per code-producing agent, one pane per agent, all in the goal
workspace's default tab:

```bash
# single writer
herdr worktree create --cwd /path/to/repo --branch fix/90 --label fix-90 --no-focus
ccw fix-90 --role build --cwd /path/to/wt-90 --tab <default_tab_id> --split down --no-focus

# a second, concurrent writer in the same batch
herdr worktree create --cwd /path/to/repo --branch fix/89 --label analyse-89 --no-focus
ccw analyse-89 --role analyse --cwd /path/to/wt-89 --tab <default_tab_id> --split down --no-focus

# the verifier reads the same worktree the writer used — it does not get a
# worktree of its own, and it is dispatched every time
ccw verify-90 --role verify --cwd /path/to/wt-90 --tab <default_tab_id> --split down --no-focus

# the reviewer, same worktree, same rule — but only if review was requested
ccw review-90 --role review --cwd /path/to/wt-90 --tab <default_tab_id> --split down --no-focus
```

### Services — their own tab, same workspace, reported to the status bar

`ccw --new-tab` shells out to `herdr tab create` without a `--workspace`
argument, so it lands in whatever workspace the orchestrator's own pane is
currently in. If that happens to be the goal workspace, `ccw <svc-name>
--role mechanical --cwd <path> --new-tab <svc-name> --no-focus` is enough. If
it is not, create the service tab explicitly against the goal workspace
instead, then start copilot into its root pane the same way `ccw` would:

```bash
herdr tab create --workspace <goal_workspace_id> --label svc-api --cwd /path/to/repo --no-focus
# -> result.tab.tab_id, result.root_pane.pane_id
herdr agent start svc-api --kind copilot --pane <root_pane_id> --timeout 120000 \
  -- --model gpt-5.6-luna --effort low --allow-all   # role flags from lib/roles.sh
```

Either way, once the service tab exists, report it into the workspace's status
bar so its name stays visible without you re-stating it:

```bash
herdr workspace report-metadata <goal_workspace_id> --source orchestrator \
  --token svc-api=svc-api
```

`tokens` is a flat `NAME=VALUE` map (key pattern `[A-Za-z0-9_-]{1,32}`,
max 16 entries) that shows up in `herdr workspace get` and in herdr's own
workspace status bar — this is the one supported mechanism for surfacing a
service's tab name; there is no separate Copilot-side status bar API. Clear a
stale entry with `--clear-token <NAME>` when the service tab closes.

### Deliver the brief

One command. `herdr agent prompt` submits the text *and* the Enter atomically,
honouring the pane's bracketed-paste mode. The old `agent send` plus
`pane send-keys <pane_id> Enter` pair is gone — do not reach for it.

```bash
herdr agent prompt <name> "<brief>" --wait --timeout 900000
```

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

## 7. Supervise

Never send input to a pane whose `agent_status` is `working` or `blocked`.
Block properly instead.

`agent prompt --wait` already waits for the first settled `idle`, `done` or
`blocked` state, so most tasks need nothing more. Use a standalone wait when you
are picking up an agent someone else prompted, or waiting for a specific state:

```bash
herdr agent wait <name> --timeout 900000                 # idle|done|blocked
herdr agent wait <name> --until blocked --timeout 120000 # it wants input
herdr agent read <name> --source recent-unwrapped --lines 80
```

`--wait` needs an observed state change within 5s of submission or it returns
`agent_prompt_stalled`. It tracks lifecycle state, not turns: if the agent was
already working, that turn's completion can satisfy the wait.

A long task can outlive a `--timeout`. A timeout is not a failure — re-check
with `herdr agent get <name>` and wait again.

Bound every read with `--lines`. When three or more tasks are in flight,
sketch the dependency order before dispatching anything and hold the merge
order yourself. Workers never talk to each other; blockers come to you.

### Verified command reference (herdr 0.8.0)

```
herdr workspace create --label <LABEL> --cwd <PATH> --no-focus
                                                             -> result.workspace.workspace_id
                                                                result.tab.tab_id
                                                                result.root_pane.pane_id
herdr tab rename <TAB_ID> <LABEL>
herdr tab create --workspace <WORKSPACE_ID> --label <LABEL> --cwd <PATH> --no-focus
                                                             -> result.tab.tab_id
                                                                result.root_pane.pane_id
herdr pane split --current --direction <right|down> --cwd <PATH> --no-focus
                                                             -> result.pane.pane_id
herdr pane split --pane <PANE_ID> --direction <right|down> --cwd <PATH> --no-focus
                                                             -> result.pane.pane_id
herdr worktree create --cwd <PATH> --branch <NAME> --label <LABEL> --no-focus
herdr tab list                                               -> result.tabs[]
herdr agent list                                             -> result.agents[]
herdr agent start <name> --kind copilot --pane <pane-id> [--timeout MS] -- <copilot args>
herdr agent get <name>                                       -> result.agent.pane_id
                                                                result.agent.agent_status
herdr agent prompt <name> "<text>" --wait [--until STATUS] [--timeout MS]
herdr agent wait <name> [--until STATUS] [--timeout MS]
herdr agent read <name> --source recent-unwrapped --lines <N>
herdr agent send-keys <name> <esc|ctrl+c>
herdr workspace get <WORKSPACE_ID>                           -> result.workspace.tokens
herdr workspace report-metadata <WORKSPACE_ID> --source <ID> --token <NAME=VALUE>
herdr pane list --workspace <workspace_id>                   -> result.panes[]
herdr pane close <pane_id>
herdr workspace close <workspace_id>
```

Read sources: `visible`, `recent`, `recent-unwrapped` (prefer for transcripts),
`detection`. Copilot runs on the alternate screen, so rows that scroll away
never reach herdr's scrollback and a bigger `--lines` will not recover them. If
a response will not fit, ask the worker to write it to a file and reply with the
path, then read the file.

## 8. Verify

**A verifier session receives the DoD verbatim and never sees the worker's
report.** That is the point — a verifier that has read the worker's summary is
grading the summary, not the code.

Dispatch it as its own agent at the `verify` role.

Floor: you still read the changed files yourself whenever a protected path or
an interface is touched.

**Verification is mandatory and is the default stopping point.** A passing
`verify` pass is enough to report the work done and clean up — proceed
straight to Clean up and Report unless adversarial review below is explicitly
in scope.

## 9. Review (optional) — before the PR, not required

**Review is off by default for now.** Only dispatch it when the user
explicitly asks for a review, or explicitly asks the change be prepared as a
PR and wants it checked first. Nothing about completing this skill's lifecycle
requires it, and skipping it is not a shortcut you have to justify — it is the
default path. Treat it as a phase you wire in on request, the same way you
would opt into `factory` or `hard`.

When it is in scope, the reasoning for running it still holds: the verifier
answered a closed question — does this meet the stated criteria? A change can
pass that while being inert, bypassable, or applied to one instance of a
problem that exists in forty places. Review asks the open question instead:
**what is wrong with this that nobody thought to check?**

Dispatch it as its own agent at the `review` role, in the same goal workspace's
default tab as everyone else, reading the same worktree the writer used. It is
not a subagent and it is not you reading the diff again.

```bash
ccw review-90 --role review --cwd /path/to/wt-90 --tab <default_tab_id> --split down --no-focus
```

**It receives the diff, the task and the DoD. It never receives the
implementer's report** — same rule as the verifier, and for the same reason.
It loads the `pre-pr-review` skill, which holds the investigation lines:
effect rather than substitution, guardrail integrity, generalisation gap,
blind spots in the DoD itself, and scope in both directions.

It returns numbered findings, each with a file reference or a command and its
exit code, split into `BLOCKER`, `SHOULD FIX` and `NOTE`, and one final
verdict line, present exactly once and never earlier in the report. Read only
that final line — do not grep the whole report, since a stray token in a
quoted example or discussion earlier would be misread as the verdict:

- `REVIEW: CLEAR` — create the PR.
- `REVIEW: BLOCKED` — **no PR is created** until every blocker is corrected.

When review was run, its findings feed the existing single correction pass
below. They do not buy a second one.

## 10. Correct once

One correction, sent to the **same** agent with another `agent prompt`,
whether the finding came from a failed `verify` or, if run, a `review` verdict
of `BLOCKED`. If it misses again, escalate to the user. Twice missed means the
brief was wrong, not the worker.

## 11. Clean up

A pane is closable when `herdr agent get <name>` reports `agent_status`
`idle` or `done`. Do not call `pane process-info` on a copilot worker pane — the
copilot REPL is always a foreground process there, so the "no foreground
process" test can never pass. Reserve `process-info` for panes running a
non-copilot long-running command.

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

`svc-` panes never auto-close, and neither does the workspace they live in
alongside the delivery batch. Workers never daemonize — long-lived processes
are started by you, in named `svc-` tabs, with a note recording what the
service is pinned to (branch, commit, port, config), and cleared from the
workspace's status bar with `--clear-token` when the service tab closes.

Once every pane in the goal workspace is idle or done and the batch has been
reported, close the workspace itself:

```bash
herdr workspace close <workspace_id>
```

## 12. Report

Tell the user what was delegated, under which workspace, tab and agent name,
and what the verdict was. Names, not pane ids. Say plainly whether review ran
or was skipped by default — do not imply it happened when it did not.

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
