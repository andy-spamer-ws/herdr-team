# herdr-team

An orchestrator pattern for the GitHub Copilot CLI. A lead session refuses to do
delivery work itself. It reads enough to write a precise brief, dispatches a
named worker into a herdr pane, supervises that worker through herdr's
agent-status API, verifies the result against a definition of done, and cleans
the pane up.

The problem it solves: a single long-running Copilot session doing all the work
burns its context on file dumps, test output and build noise, then compacts and
loses the plan. Splitting the roles fixes that. The lead keeps the dependency
graph, the briefs and the open decisions. Everything else runs in a separate
pane, at the cheapest model that can do the job, and comes back as a verdict.

## Requirements

[herdr](https://github.com/herdr-dev/herdr) **0.8.0 or newer** is required for
`ccw` — it hard-fails if herdr is not on PATH. `ccd` degrades instead: if herdr
is missing it prints `ccd: herdr not on PATH — running copilot bare` to stderr
and execs `copilot` directly, with the orchestrator agent still applied.

0.8.0 is a floor, not a preference. In 0.8.0 `herdr agent start` takes `--kind`
and `--pane` and never creates layout, so `ccw` acquires the pane itself and
then starts Copilot into it. On 0.7.x that command does not exist in this shape
and nothing dispatches. `orchestrate-doctor` fails the run if herdr is older.

There is no tmux fallback and no multiplexer abstraction. `ccd` and `ccw` shell
out to `herdr pane split`, `herdr tab create`, `herdr agent start` and
`herdr pane close` directly and parse herdr's JSON.

Beyond herdr, the only requirements are `bash`, `python3` and `copilot`.

## What is in the bundle

```
README.md
LICENSE                                  MIT, this bundle's own code
.gitignore                               ignore macOS .DS_Store metadata
install.sh                               symlink the bundle into PATH and ~/.copilot
uninstall.sh                             remove only what it installed
bin/ccd                                  launcher: herdr session + --agent orchestrator
bin/ccw                                  worker dispatcher: name + role -> model, pane, agent start
bin/orchestrate-doctor                   readiness check
lib/roles.sh                             the role-to-model table, shared by ccd and ccw
agents/orchestrator.md                   the delegation-only agent definition
agents/pre-pr-reviewer.md                the adversarial pre-PR review agent definition
skills/orchestrate/SKILL.md              the 11-step lifecycle and command reference
skills/pre-pr-review/SKILL.md            the investigation lines the reviewer works from
prompts/sr_opus_5_system_prompt.md       vendored SR communication addendum
prompts/LICENSE-fixing-smartass-opus-5   its MIT licence
```

`ccd` starts the orchestrator. `ccw` is what the orchestrator uses to start
workers. The agent definition is what makes the lead refuse to do the work
itself. The skill is what tells it how to dispatch properly.

## Install

```bash
./install.sh --dry-run     # see everything it would do
./install.sh
```

It creates seven symlinks, all pointing back into the bundle:

| Symlink | Target |
|---------|--------|
| `<prefix>/ccd` | `<bundle>/bin/ccd` |
| `<prefix>/ccw` | `<bundle>/bin/ccw` |
| `<prefix>/orchestrate-doctor` | `<bundle>/bin/orchestrate-doctor` |
| `<copilot-dir>/agents/orchestrator.md` | `<bundle>/agents/orchestrator.md` |
| `<copilot-dir>/agents/pre-pr-reviewer.md` | `<bundle>/agents/pre-pr-reviewer.md` |
| `<copilot-dir>/skills/orchestrate` | `<bundle>/skills/orchestrate` |
| `<copilot-dir>/skills/pre-pr-review` | `<bundle>/skills/pre-pr-review` |

and appends one managed block to `<copilot-dir>/copilot-instructions.md` — see
[Vendored prompt](#vendored-prompt).

Options:

- `--prefix DIR` — where the three commands go. Default `$HOME/bin`.
- `--copilot-dir DIR` — your Copilot CLI config dir. Default `$HOME/.copilot`.
- `--force` — replace a symlink that points somewhere else.
- `--dry-run` — print every action, change nothing.

Running it twice is a no-op, not an error. A regular file or directory sitting
at one of those destinations is never clobbered, with or without `--force`: the
run names the blocking path and exits non-zero so you can move it aside
yourself. A `mkdir` or `ln -s` failure (for example, a permission error) is
reported the same way — a `FAILED` line naming the exact path and the reason,
counted separately from successful links in the summary, with a non-zero exit.
If a run ends with any `BLOCKED` or `FAILED` entries, either some links were
created and some were not, or nothing was installed at all; rerunning after
clearing the blockers is safe because `install.sh` is idempotent.

Because the installed commands are symlinks, both scripts resolve their own
symlink chain at runtime to find the bundle root, then read the role table from
`<bundle>/lib/`. Nothing is hardcoded to an absolute path, so you can move the
bundle and rerun `install.sh --force`.

## Uninstall

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

It removes a symlink only when its resolved target is inside this bundle.
Anything else is reported and left alone. The addendum block is cut out of
`copilot-instructions.md` by its BEGIN/END markers, leaving everything else in
that file byte-for-byte intact; if the markers are damaged it says so and
changes nothing. The bundle directory itself is never touched.

## Roles

The model is the dial. Effort is a deviation from it, not a second dial.

| Role | Flags `ccw` applies | Use for |
|------|---------------------|---------|
| `mechanical` | `--model gpt-5.6-luna --effort low` | Rename, move, delete, mechanical edits |
| `build` | `--model claude-sonnet-5 --effort medium` | Write the code, write the tests |
| `verify` | `--model gpt-5.6-terra --effort medium` | Run the DoD, read the diff, pass/fail |
| `review` | `--model claude-opus-5 --effort xhigh` | Adversarial pre-PR pass, find defects nobody specified |
| `analyse` | `--model claude-opus-5 --effort xhigh` | Find out why, read across modules |
| `hard` | `--model claude-opus-5 --effort max --context long_context` | Design, tricky concurrency, migrations |
| `orchestrator` | `--model gpt-5.6-sol --effort high --context long_context` | What `ccd` runs you as |

Bias up when the right role is unclear — but the spread is wide. `orchestrator`
and `hard` cost roughly 25x per token what `mechanical` does, and
`--context long_context` roughly doubles the rate again on the OpenAI models.
The pattern only pays for itself if the expensive roles delegate instead of
typing.

The table lives in one place, `lib/roles.sh`, and both `ccd` and `ccw` source it.
Change a model there, not in a script.

`claude-haiku-4.5` is deliberately absent: it rejects `--effort` outright, which
would need a special case in every caller, and `gpt-5.6-luna` is cheaper anyway.

`--tier` still works as an alias for `--role`.

## First dispatch

Start the orchestrator in the repo you want worked on:

```bash
cd /path/to/repo
ccd
```

That opens a herdr session, creates a tab named `orch-<dirname>`, and boots
Copilot in it with the `orchestrator` agent at the orchestrator role.

From there the orchestrator stays in that same workspace and tab — it never
opens a new one — and puts every worker for the current goal in a pane there,
on its own isolated git worktree, never the checkout the orchestrator itself is
sitting in:

```bash
herdr pane get "$HERDR_PANE_ID"
# -> result.pane.workspace_id (the current workspace), result.pane.tab_id (the current tab)

git -C /path/to/repo worktree add -b fix/90 /path/to/wt-90
```

Check the argv first — it prints the exact commands and launches nothing:

```bash
ccw fix-90 --role build --cwd /path/to/wt-90 --tab <tab-id> --split down --no-focus --dry-run
```

Then dispatch for real:

```bash
ccw fix-90 --role build --cwd /path/to/wt-90 --tab <tab-id> --split down --no-focus
# started fix-90  pane w8:p4  role build  model claude-sonnet-5
```

Send the brief. One command does the text and the Enter, atomically:

```bash
herdr agent prompt fix-90 "TASK: ...

CONTEXT:
- ...

DO:
1. ...

DONE WHEN:
- ...

DO NOT:
- ..." --wait --timeout 900000
```

`--wait` already blocks until the agent settles on `idle`, `done` or `blocked`.
Read the result by agent name, never by polling a working pane:

```bash
herdr agent read fix-90 --source recent-unwrapped --lines 80
```

Clean up when the agent reports `idle` or `done`:

```bash
herdr agent get fix-90            # -> result.agent.pane_id, result.agent.agent_status
herdr pane close <pane_id>
```

For a second, concurrent writer in the same batch, give it its own worktree but
the same current workspace and the same current tab:

```bash
git -C /path/to/repo worktree add -b analyse/89 /path/to/wt-89
ccw analyse-89 --role analyse --cwd /path/to/wt-89 --tab <tab-id> --split down --no-focus
```

A long-lived service gets its own tab, prefixed `svc-`, but stays in the same
current workspace — and its tab name gets reported into the workspace's status
bar so it stays visible:

```bash
ccw svc-api --role mechanical --cwd /path/to/repo --new-tab svc-api --no-focus
herdr workspace report-metadata <workspace-id> --source orchestrator --token svc-api=svc-api
```

`ccw` needs `HERDR_PANE_ID` set unless you pass `--tab` or `--new-tab`, because
its default placement splits the pane you are in. Because the orchestrator's
own pane is always in the current workspace, `--new-tab` always lands there
too.

The full lifecycle — Scope, Space, Route, Name, Role, Dispatch, Supervise,
Verify, Review (optional), Correct once, Clean up, Report — is in
`skills/orchestrate/SKILL.md`, along with the routing table and the verified
herdr 0.8.0 command reference. Verification is mandatory; adversarial review
is off by default and only dispatched when explicitly requested.

## The doctor

```bash
orchestrate-doctor
```

Reports every check on its own line and never stops at the first problem.

- `PASS` — fine.
- `WARN` — not fatal. The toolchain still runs, but something is degraded or a
  different copy of a component is the one actually active.
- `FAIL` — something required is missing. The remedy is on the same line.

Checks: bash version (warn only, under 3.2), `herdr` on PATH **and at least
0.8.0**, `copilot` accepted as a `herdr agent start --kind`, `copilot` on PATH,
`python3` on PATH, `HERDR_ENV` (informational — it is only set inside a herdr
pane), the addendum source being readable and its block being installed,
`orchestrator.md` and the `orchestrate` skill installed and resolving back into
this bundle, `pre-pr-reviewer.md` and the `pre-pr-review` skill installed and
resolving back into this bundle, and `ccd` and `ccw` on PATH resolving back
into this bundle.

For the last six, severity depends on what is actually there. Missing entirely
is a `FAIL` — run `./install.sh`. Resolving into this bundle is a `PASS`.
Present and working but resolving somewhere else is a `WARN`: that is the
expected state when this bundle sits alongside an existing install, nothing is
broken, and `./install.sh --force` is how you switch over if you want to.

It exits 0 when nothing failed, 1 otherwise. Warnings never change the exit
status, so a run with warnings and no failures still reads as ready.

## Vendored prompt

`prompts/sr_opus_5_system_prompt.md` is not mine. It is the "clear, concise,
actionable" communication addendum from
[disler/fixing-smartass-opus-5](https://github.com/disler/fixing-smartass-opus-5),
MIT licensed, Copyright (c) 2026 IndyDevDan. Its licence text is preserved
verbatim at `prompts/LICENSE-fixing-smartass-opus-5`. It is vendored unchanged
and stays under its own licence — the bundle's MIT licence covers only the
bundle's own code.

The Copilot CLI has no `--append-system-prompt`, so there is nothing to pass at
launch. `install.sh` appends the addendum once to
`<copilot-dir>/copilot-instructions.md`, wrapped in

```
<!-- BEGIN herdr-team SR addendum (managed) -->
<!-- END herdr-team SR addendum (managed) -->
```

From there it applies to every Copilot session on the machine, orchestrator and
worker alike, with no per-launch flag. Installing twice does not duplicate it;
`uninstall.sh` removes exactly that block and nothing else. It ships inside the
bundle — nothing is fetched at install time.

That is a real trade against the old behaviour: the addendum is now global, not
scoped to sessions this bundle launched. If you do not want it applied to every
Copilot session, delete the block after installing; everything else keeps
working, and `orchestrate-doctor` will report it as a `WARN`, not a `FAIL`.

`ccd` looks for `agents/orchestrator.md` under `$CCD_COPILOT_DIR`, defaulting to
`$HOME/.copilot` — the same default `install.sh` and `orchestrate-doctor` use
for their `--copilot-dir` flag. Set `CCD_COPILOT_DIR` when you installed with a
non-default `--copilot-dir`, otherwise `ccd` looks in the wrong place and
silently drops into a plain, non-orchestrator session.

## Limitations

- **No Claude Code support, and none planned.** This bundle drives the GitHub
  Copilot CLI. `ccw` hard-fails without herdr; `ccd` degrades to a bare
  `copilot` launch with a warning on stderr.
- **Written against herdr 0.8.0.** The command reference in the skill and the
  JSON paths the scripts parse (`result.pane.pane_id`, `result.root_pane.pane_id`,
  `result.tab.tab_id`, `result.agent.name`, `result.agents[]`) are verified
  against that version. A herdr release that changes those shapes will break
  dispatch.
- **The model list is account- and plan-dependent.** The roles name specific
  models. Legacy multiplier-billing Copilot plans do not get the newer models at
  all, and an unavailable model makes `copilot` exit at launch — which surfaces
  as a `herdr agent start` failure from `ccw`, not as a model error. If a role
  will not start, run its `--model` by hand with `copilot -p` to see the real
  message.
- **Agent names are constrained by herdr.** They must match
  `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. `ccw` rejects
  anything else up front; `ccd` sanitises the directory name it derives.
- **Tested on Linux with bash 5.3.** The scripts are still deliberately
  bash-3.2 compatible — no associative arrays, no `declare -n`, no `${var^^}`,
  no `readlink -f`, no `realpath` — so they should run on stock macOS, but that
  is currently untested.
- **No config file, no plugin system.** Behaviour is set by flags and the
  environment variables the scripts document.
- **The orchestrator's restraint is mostly a prompt.** The agent definition
  withholds the `edit` and `create` tools, which herdr-team verifies Copilot
  actually enforces, and it runs with `--allow-all`. But `bash` remains in the
  tool list because dispatch needs it, and `bash` can write files by
  redirection. The agent definition forbids that explicitly. Nothing but the
  model stops it.
