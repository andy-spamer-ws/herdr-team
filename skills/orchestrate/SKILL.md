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

1. Every `/orchestrate` invocation binds to the **orchestrator's current herdr
   workspace and current tab** — it never opens a new workspace.
2. Every task, subagent, verifier, reviewer and worker for that invocation is a
   **pane in that same current tab**, alongside the orchestrator's own pane.
3. Shell commands that need their own pane and long-lived services may use
   **separate tabs**, but always inside the same current workspace — never a
   workspace or session of their own.
4. All code-producing work runs against an **isolated git worktree**, added
   with plain `git worktree add` (never herdr's own `worktree create`, which opens
   its own workspace), and never the checkout the orchestrator itself is
   sitting in.
5. Every service tab launched is reported into the **workspace's status bar**
   via `herdr workspace report-metadata`, so its tab name stays visible without
   you having to keep saying it.

These are functional, not stylistic: they are how the user watching the herdr
UI finds the whole batch — worker, verifier, reviewer, and any services — in
one place, right where they already are, without hunting across tabs or
workspaces.

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

## 2. Space — resolve the current workspace and tab, do not create one

There is nothing to open. Resolve the ids you are already sitting in and reuse
them for the whole invocation:

```bash
herdr pane get "$HERDR_PANE_ID"
# -> result.pane.workspace_id  (the current workspace — reuse it for everything)
#    result.pane.tab_id        (the current tab — every delivery pane goes here)
```

That current tab is where every task, subagent, verifier, reviewer and worker
for this invocation lives, each as its own pane, alongside the orchestrator's
own pane. There is no paneless exception — read-only research and review get a
pane there too, at the `analyse` or `review` role. Renaming the tab is
optional, and if you do it, rename the tab you are already in — never create a
new one first: `herdr tab rename <tab_id> "<meaningful batch name>"`.

Because the orchestrator's own pane is always inside this workspace now,
`ccw`'s `--tab <ID>` form (addressing the current tab id from above) and
`ccw --new-tab` (for a service, see Dispatch below) both land correctly with
no special-casing.

Every code-producing worker gets an isolated git worktree, added with plain
`git worktree add` (not herdr's own `worktree create`, which opens a workspace of its
own) — never the checkout the orchestrator itself is sitting in, including a
lone, sequential writer. Services keep their own tab in this same workspace,
prefixed `svc-`, and their tab name gets surfaced through
`herdr workspace report-metadata` (see Dispatch). Never close the current
workspace or the current tab — the orchestrator's own pane lives there for the
rest of the session.

## 3. Route — cheapest substrate that works

| Situation | Substrate |
|-----------|-----------|
| Read-only research or review | Pane in the current tab, `analyse` or `review` role. |
| Single writer | Pane in the current tab, on its own isolated `git worktree add`. |
| Two or more concurrent writers | Same current tab, one pane and one isolated worktree each. |
| A shell command that needs its own long-running pane | Separate tab in the **same** current workspace. |
| Long-lived service | New tab in the **same** current workspace, prefixed `svc-`. |
| Acceptance criterion writable up front **and** repo is factory-stamped | `factory run <workflow>` |

**The factory test is one question: can you write the acceptance criterion
before the work starts?** Yes plus a stamped repo means factory. No means a
named copilot pane.

Run `factory doctor`, the read-only readiness check, to verify whether a repo is factory-stamped.

## 4. Name

Every work item carries a unique name.

- **Current workspace and current tab already exist** — nothing here needs
  naming or creating; renaming the current tab to describe the batch is
  optional.
- **Agent = the task.** `analyse-89`, `fix-90`
- **Worktree label matches the agent name.**
- **Service tab = `svc-<name>`**, still inside the current workspace.

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
the default placement splits the pane you are in. Address every delivery pane
by the current tab id resolved in Space, above.

### Every delivery agent — same current workspace, same current tab

One isolated git worktree per code-producing agent, one pane per agent, all in
the current tab:

```bash
# single writer — plain git, not herdr's own worktree create (that opens a workspace)
git -C /path/to/repo worktree add -b fix/90 /path/to/wt-90
ccw fix-90 --role build --cwd /path/to/wt-90 --tab <current_tab_id> --split down --no-focus

# a second, concurrent writer in the same batch
git -C /path/to/repo worktree add -b analyse/89 /path/to/wt-89
ccw analyse-89 --role analyse --cwd /path/to/wt-89 --tab <current_tab_id> --split down --no-focus

# the verifier reads the same worktree the writer used — it does not get a
# worktree of its own, and it is dispatched every time
ccw verify-90 --role verify --cwd /path/to/wt-90 --tab <current_tab_id> --split down --no-focus

# the reviewer, same worktree, same rule — but only if review was requested
ccw review-90 --role review --cwd /path/to/wt-90 --tab <current_tab_id> --split down --no-focus
```

When a worker's pane closes (see Clean up), remove its worktree so the repo
does not accumulate stale checkouts:

```bash
git -C /path/to/repo worktree remove /path/to/wt-90
git -C /path/to/repo worktree prune
```

### Services — their own tab, same current workspace, reported to the status bar

Because the orchestrator's own pane is always inside the current workspace,
`ccw <svc-name> --role mechanical --cwd <path> --new-tab <svc-name> --no-focus`
always lands in the right place — no special-casing needed.

```bash
ccw svc-api --role mechanical --cwd /path/to/repo --new-tab svc-api --no-focus
```

Once the service tab exists, report it into the workspace's status bar so its
name stays visible without you re-stating it:

```bash
herdr workspace report-metadata <current_workspace_id> --source orchestrator \
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
herdr pane get <PANE_ID>                                     -> result.pane.workspace_id
                                                                result.pane.tab_id
herdr tab rename <TAB_ID> <LABEL>
herdr pane split --current --direction <right|down> --cwd <PATH> --no-focus
                                                             -> result.pane.pane_id
herdr pane split --pane <PANE_ID> --direction <right|down> --cwd <PATH> --no-focus
                                                             -> result.pane.pane_id
git worktree add -b <BRANCH> <PATH>
git worktree remove <PATH>
git worktree prune
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

Dispatch it as its own agent at the `review` role, in the same current tab as
everyone else, reading the same worktree the writer used. It is not a subagent
and it is not you reading the diff again.

```bash
ccw review-90 --role review --cwd /path/to/wt-90 --tab <current_tab_id> --split down --no-focus
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

Closing every delivery agent pane in the current tab leaves the orchestrator's
own pane and, if you split any bare shells while working, those too. Find and
close those leftovers:

```bash
herdr pane list --workspace <workspace_id>
herdr pane close <pane_id>
```

`svc-` panes never auto-close. Workers never daemonize — long-lived processes
are started by you, in named `svc-` tabs, with a note recording what the
service is pinned to (branch, commit, port, config), and cleared from the
workspace's status bar with `--clear-token` when the service tab closes.

Never close the current workspace or the current tab — the orchestrator's own
pane lives there for the rest of the session. Once every delivery pane from
this invocation is idle or done, its worktree removed (`git worktree remove`,
then `git worktree prune`), and the batch has been reported, the invocation is
finished; nothing further needs closing.

## 12. Report

Tell the user what was delegated, in which tab, under which agent names, and
what the verdict was. Names, not pane ids. Say plainly whether review ran or
was skipped by default — do not imply it happened when it did not.

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
