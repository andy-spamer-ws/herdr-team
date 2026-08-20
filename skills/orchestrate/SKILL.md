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

The lifecycle, in order: **Scope → Route → Name → Role → Dispatch → Supervise
→ Verify → Review → Correct once → Clean up → Report.**

Workers are GitHub Copilot CLI sessions in herdr panes. This skill is written
against **herdr 0.8.0**, where `herdr agent start` takes `--kind` and `--pane`
and never creates layout of its own.

---

## When to use / when not to

| Use it | Do not use it |
|--------|---------------|
| Any unit of delivery work: edit, build, test, migrate, refactor, commit | Answering a question inline |
| A batch of related issues that needs a dependency order | Reading code back to the user |
| Two or more independent writers that could run at once | A decision the user has to make first |
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

## 2. Route — cheapest substrate that works

| Situation | Substrate |
|-----------|-----------|
| Read-only research or review | `task` subagent. No pane. |
| Single writer, sequential | Named pane in the current tab. |
| Two or more concurrent writers | **New named tab**, one herdr worktree plus one pane per writer. |
| Different repo, or a long-lived service | New tab, name prefixed `svc-`. |
| Acceptance criterion writable up front **and** repo is factory-stamped | `factory run <workflow>` |

**The factory test is one question: can you write the acceptance criterion
before the work starts?** Yes plus a stamped repo means factory. No means a
named copilot pane.

Run `factory doctor`, the read-only readiness check, to verify whether a repo is factory-stamped.

## 3. Name

Every work item carries a unique name.

- **Tab = the batch.** `issue-89-90`
- **Agent = the task.** `analyse-89`, `fix-90`
- **Worktree label matches the agent name.**

herdr requires agent names to match `[a-z][a-z0-9_-]{0,31}` and be unique among
live agents. `ccw` rejects anything else before it touches herdr.

Pane ids (`w16:p4`) are an implementation detail. Never use one when talking to
the user — use the agent name. Agent commands accept either.

## 4. Role — the model is the dial, effort is a deviation

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

## 5. Dispatch — `ccw` is THE command

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

Concrete shapes:

```bash
# single writer, pane in this tab
ccw fix-90 --role build --cwd /path/to/repo --split right --no-focus

# batch of two concurrent writers in their own tab and worktrees
herdr worktree create --cwd /path/to/repo --branch fix/89 --label analyse-89 --no-focus
ccw analyse-89 --role analyse --cwd /path/to/wt-89 --new-tab issue-89-90 --no-focus
ccw fix-90     --role build   --cwd /path/to/wt-90 --tab <tab-id> --split down --no-focus

# long-lived service, never auto-closed
ccw svc-api --role mechanical --cwd /path/to/repo --new-tab svc-api --no-focus
```

`ccw` needs `HERDR_PANE_ID` set unless you pass `--tab` or `--new-tab`, because
the default placement splits the pane you are in.

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

## 6. Supervise

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
herdr pane split --current --direction <right|down> --cwd <PATH> --no-focus
                                                             -> result.pane.pane_id
herdr tab create --label <LABEL> --cwd <PATH> --no-focus     -> result.tab.tab_id
                                                                result.root_pane.pane_id
herdr tab list                                               -> result.tabs[]
herdr agent list                                             -> result.agents[]
herdr agent start <name> --kind copilot --pane <pane-id> [--timeout MS] -- <copilot args>
herdr agent get <name>                                       -> result.agent.pane_id
                                                                result.agent.agent_status
herdr agent prompt <name> "<text>" --wait [--until STATUS] [--timeout MS]
herdr agent wait <name> [--until STATUS] [--timeout MS]
herdr agent read <name> --source recent-unwrapped --lines <N>
herdr agent send-keys <name> <esc|ctrl+c>
herdr pane list --workspace <workspace_id>                   -> result.panes[]
herdr pane close <pane_id>
```

Read sources: `visible`, `recent`, `recent-unwrapped` (prefer for transcripts),
`detection`. Copilot runs on the alternate screen, so rows that scroll away
never reach herdr's scrollback and a bigger `--lines` will not recover them. If
a response will not fit, ask the worker to write it to a file and reply with the
path, then read the file.

## 7. Verify

**A verifier session receives the DoD verbatim and never sees the worker's
report.** That is the point — a verifier that has read the worker's summary is
grading the summary, not the code.

Dispatch it as its own agent at the `verify` role.

Floor: you still read the changed files yourself whenever a protected path or
an interface is touched.

## 8. Review — before the PR, not after

The verifier answered a closed question: does this meet the stated criteria? A
change can pass that while being inert, bypassable, or applied to one instance
of a problem that exists in forty places. The review stage asks the open
question instead: **what is wrong with this that nobody thought to check?**

Dispatch it as its own agent at the `review` role. It is not a subagent and it
is not you reading the diff again.

```bash
ccw review-90 --role review --cwd /path/to/repo --split right --no-focus
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

Its findings feed the existing single correction pass below. They do not buy a
second one.

## 9. Correct once

One correction, sent to the **same** agent with another `agent prompt`. If it
misses again, escalate to the user. Twice missed means the brief was wrong, not
the worker.

## 10. Clean up

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

`svc-` panes never auto-close. Workers never daemonize — long-lived processes
are started by you, in named `svc-` panes, with a note recording what the
service is pinned to (branch, commit, port, config).

## 11. Report

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
