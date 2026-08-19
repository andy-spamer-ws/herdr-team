# herdr-team

An orchestrator pattern for Claude Code. A lead session refuses to do delivery
work itself. It reads enough to write a precise brief, dispatches a named
worker into a herdr pane, supervises that worker through herdr's agent-status
API, verifies the result against a definition of done, and cleans the pane up.

The problem it solves: a single long-running Claude session doing all the work
burns its context on file dumps, test output and build noise, then compacts and
loses the plan. Splitting the roles fixes that. The lead keeps the dependency
graph, the briefs and the open decisions. Everything else runs in a separate
pane, at the cheapest model tier that can do the job, and comes back as a
verdict.

## herdr is a hard dependency for ccw, a soft one for ccd

[herdr](https://github.com/herdr-dev/herdr) is required for `ccw` — it hard-fails
if herdr is not on PATH. `ccd` degrades instead: if herdr is missing it prints
`ccd: herdr not on PATH — running claude bare` to stderr and execs `claude`
directly, with the addendum and orchestrator agent still applied. There is no
tmux fallback and no multiplexer abstraction — when herdr is present, `ccd` and
`ccw` shell out to `herdr agent start`, `herdr agent wait`, `herdr agent read`
and `herdr pane close` directly, and the orchestrate skill's command reference
is written against herdr 0.7.3's JSON shapes.

Beyond herdr, the only requirements are `bash`, `python3` and `claude`.

## What is in the bundle

```
README.md
LICENSE                                  MIT, this bundle's own code
.gitignore                               ignore macOS .DS_Store metadata
install.sh                               symlink the bundle into PATH and ~/.claude
uninstall.sh                             remove only the symlinks it created
bin/ccd                                  launcher: herdr session + addendum + --agent orchestrator
bin/ccw                                  worker dispatcher: name + tier -> model, herdr agent start
bin/orchestrate-doctor                   readiness check
agents/orchestrator.md                   the delegation-only agent definition
skills/orchestrate/SKILL.md              the 10-step lifecycle and command reference
prompts/sr_opus_5_system_prompt.md       vendored SR communication addendum
prompts/LICENSE-fixing-smartass-opus-5   its MIT licence
```

`ccd` starts the orchestrator. `ccw` is what the orchestrator uses to start
workers. The agent definition is what makes the lead refuse to do the work
itself. The skill is what tells it how to dispatch properly.

## Install

```bash
./install.sh --dry-run     # see every symlink it would create
./install.sh
```

It creates five symlinks, all pointing back into the bundle:

| Symlink | Target |
|---------|--------|
| `<prefix>/ccd` | `<bundle>/bin/ccd` |
| `<prefix>/ccw` | `<bundle>/bin/ccw` |
| `<prefix>/orchestrate-doctor` | `<bundle>/bin/orchestrate-doctor` |
| `<claude-dir>/agents/orchestrator.md` | `<bundle>/agents/orchestrator.md` |
| `<claude-dir>/skills/orchestrate` | `<bundle>/skills/orchestrate` |

Options:

- `--prefix DIR` — where the three commands go. Default `$HOME/bin`.
- `--claude-dir DIR` — your Claude Code config dir. Default `$HOME/.claude`.
- `--force` — replace a symlink that points somewhere else.
- `--dry-run` — print every action, change nothing.

Running it twice is a no-op, not an error. A regular file or directory sitting
at one of those destinations is never clobbered, with or without `--force`: the
run names the blocking path and exits non-zero so you can move it aside
yourself. A `mkdir` or `ln -s` failure (for example, a permission error) is
reported the same way — a `FAILED` line naming the exact path and the reason,
counted separately from successful links in the summary, with a non-zero exit.
If a run ends with any `BLOCKED` or `FAILED` entries, either some links were created
and some were not, or nothing was installed at all; rerunning after clearing the blockers
is safe because `install.sh` is idempotent.

Because the installed commands are symlinks, both scripts resolve their own
symlink chain at runtime to find the bundle root, then read the addendum from
`<bundle>/prompts/`. Nothing is hardcoded to an absolute path, so you can move
the bundle and rerun `install.sh --force`.

## Uninstall

```bash
./uninstall.sh --dry-run
./uninstall.sh
```

It removes a destination only when it is a symlink whose resolved target is
inside this bundle. Anything else is reported and left alone. The bundle
directory itself is never touched.

## Tiers

The model is the dial. Effort is a deviation from it, not a second dial.

| Tier | Flags `ccw` applies | Use for |
|------|---------------------|---------|
| `mechanical` | `--model haiku` (no `--effort` — the model rejects it) | Rename, move, delete, mechanical edits |
| `build` | `--model sonnet` (already defaults to high) | Write the code, write the tests |
| `diagnose` | `--model opus` (already defaults to high) | Find out why, read across modules |
| `hard` | `--model opus --effort xhigh` | Design, tricky concurrency, migrations |

Bias up when the right tier is unclear.

## First dispatch

Start the orchestrator in the repo you want worked on:

```bash
cd /path/to/repo
ccd
```

That opens a herdr session, appends the SR addendum system prompt, and boots
the `orchestrator` agent in a pane named `orch-<dirname>`.

From there the orchestrator dispatches a worker. Check the argv first — it
prints the exact command and launches nothing:

```bash
ccw fix-90 --tier build --cwd /path/to/repo --split right --no-focus --dry-run
```

Then dispatch for real:

```bash
ccw fix-90 --tier build --cwd /path/to/repo --split right --no-focus
# started fix-90  pane w8:p4  tier build  model sonnet
```

Send the brief, then press Enter in the worker's pane. `send-keys` takes a pane
id positionally, never an agent name, so read the id first:

```bash
herdr agent get fix-90            # -> result.agent.pane_id
herdr agent send fix-90 "TASK: ...

CONTEXT:
- ...

DO:
1. ...

DONE WHEN:
- ...

DO NOT:
- ..."
herdr pane send-keys w8:p4 Enter
```

Supervise by blocking on status, never by polling into a pane that is working:

```bash
herdr agent wait fix-90 --status idle --timeout 600000
herdr agent read fix-90 --source recent --lines 80
```

Clean up when the agent reports `idle` or `done`:

```bash
herdr agent get fix-90            # -> result.agent.agent_status
herdr pane close w8:p4
```

For two concurrent writers, give the batch its own tab and each writer its own
worktree:

```bash
herdr worktree create --cwd /path/to/repo --branch fix/89 --label diagnose-89 --no-focus
ccw diagnose-89 --tier diagnose --cwd /path/to/wt-89 --new-tab issue-89-90 --no-focus
ccw fix-90      --tier build    --cwd /path/to/wt-90 --tab <tab-id> --split down --no-focus
```

The full lifecycle — Scope, Route, Name, Tier, Dispatch, Supervise, Verify,
Correct once, Clean up, Report — is in `skills/orchestrate/SKILL.md`, along with
the routing table and the verified herdr 0.7.3 command reference.

## The doctor

```bash
orchestrate-doctor
```

Reports every check on its own line and never stops at the first problem.

- `PASS` — fine.
- `WARN` — not fatal. The toolchain still runs, but something is degraded or a
  different copy of a component is the one actually active.
- `FAIL` — something required is missing. The remedy is on the same line.

Checks: bash version (warn only, under 3.2), `herdr` on PATH and its version,
`claude` on PATH, `python3` on PATH, `HERDR_ENV` (informational — it is only set
inside a herdr pane), the addendum being readable, `orchestrator.md` and the
`orchestrate` skill installed and resolving back into this bundle, and `ccd` and
`ccw` on PATH resolving back into this bundle.

For those last four, severity depends on what is actually there. Missing
entirely is a `FAIL` — run `./install.sh`. Resolving into this bundle is a
`PASS`. Present and working but resolving somewhere else is a `WARN`: that is
the expected state when this bundle sits alongside an existing install, nothing
is broken, and `./install.sh --force` is how you switch over if you want to.

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

Both `ccd` and `ccw` append it with `--append-system-prompt`. Resolution order
is the same in both, and neither ever hard-fails on it:

1. `$CCD_ADDENDUM` / `$CCW_ADDENDUM` if set.
2. `<bundle>/prompts/sr_opus_5_system_prompt.md`.
3. A warning on stderr, and the launch continues without it.

It ships inside the bundle. Nothing is fetched at install time.

If `$CCW_ADDENDUM` (or `$CCD_ADDENDUM`) points at a path that is not readable,
this is a silent-from-the-exit-code degradation: the script prints a warning to
stderr and still exits 0 after launching `claude` without the addendum. An
orchestrator scripting `ccw` cannot detect this from the exit code alone — it
has to check stderr if the addendum's presence matters.

`ccd` looks for `agents/orchestrator.md` under `$CCD_CLAUDE_DIR`, defaulting to
`$HOME/.claude` — the same default `install.sh` and `orchestrate-doctor` use
for their `--claude-dir` flag. Set `CCD_CLAUDE_DIR` when you installed with a
non-default `--claude-dir`, otherwise `ccd` looks in the wrong place and
silently drops into a plain, non-orchestrator session.

## Limitations

- **No tmux support, and none planned.** `ccw` hard-fails without herdr. `ccd`
  degrades to a bare `claude` launch (addendum and orchestrator agent still
  applied) with a warning on stderr. The scripts call herdr subcommands
  directly and parse herdr's JSON; there is no multiplexer abstraction.
- **Written against herdr 0.7.3.** The command reference in the skill and the
  JSON paths the scripts parse (`result.agent.pane_id`,
  `result.tab.tab_id`, `result.agents[]`) are verified against that version. A
  herdr release that changes those shapes will break dispatch.
- **Tested on macOS with bash 3.2.57 only.** The scripts are deliberately
  bash-3.2 compatible — no associative arrays, no `declare -n`, no `${var^^}`,
  no `readlink -f`, no `realpath`. They should run on Linux, but that is
  untested.
- **No config file, no plugin system.** Behaviour is set by flags and the four
  environment variables the scripts document. The tier table lives in `ccw`.
- **`install.sh` writes symlinks only.** It does not edit your shell profile.
  If the prefix directory is not on your PATH it says so and leaves it to you.
- **The orchestrator's restraint is a prompt, not a sandbox.** The agent
  definition forbids the lead from editing files, and it also runs with
  `--dangerously-skip-permissions`. Nothing enforces the boundary except the
  model following the definition.
