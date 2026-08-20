---
name: pre-pr-review
description: >-
  Adversarially review a completed change before it becomes a pull request.
  Use when development is finished, the tests pass, and a verifier has already
  signed the work off against its definition of done — the point at which the
  next step would be opening a PR. Answers the open question "what is wrong
  with this that nobody thought to check?" rather than re-running the stated
  criteria, and returns a numbered, evidence-backed finding list plus a
  REVIEW: CLEAR or REVIEW: BLOCKED verdict that decides whether the PR opens.
license: MIT
metadata:
  author: Andy Spamer
---

# Pre-PR review

## Verify and review are different questions

**VERIFY asks: does this meet the stated criteria?**
**REVIEW asks: what is wrong with this that nobody thought to check?**

Verify is a closed question. A change can pass it while being inert,
bypassable, or applied to one instance of a problem that exists in forty
places. Every criterion is green and the change still does not do what anyone
wanted.

Review is the open question. You are looking for the defects that no criterion
names, including defects in the criteria themselves.

**If your report only reproduces the verifier's checks, you have added
nothing, and that is a failed review.** Re-running the definition of done is
not review. It is verification a second time, at a higher price.

## Where this sits

Development is done. Tests pass. The verifier passed the change against its
definition of done. The next action would be opening a pull request.

You run here, before that PR exists, because your output decides whether it is
created at all.

## Why this stage exists

A real change shipped to PR 33 of Woodside/ai-maint. A scripted audit exited 0,
the type-check passed, 295 tests passed, the build succeeded, the file scope
was exactly right, and a dedicated verifier returned a detailed pass. The
automated PR reviewer immediately found two defects the whole pipeline missed.
Both were confirmed by measurement afterwards. Those two defects are the
reason lines R1 and R2 below exist, and they are quoted in place so you know
what each line is actually hunting.

---

## What you are given, and what you must not be given

**You get:**

- the diff
- the original task
- the definition of done

**You must NOT get, and must not go looking for:**

- the implementer's summary of their own work
- the verifier's report

This is the same rule that keeps the verifier away from the worker's summary.
A reviewer who reads the author's account of the change reviews the account.
You inherit the author's model of what they did, and the whole value of this
stage is that you do not share it. Read the diff and the code. If someone
hands you an implementer summary anyway, say so in your report and review the
code regardless.

---

## The investigation lines

Work each line. Each has a question, concrete probes, and the evidence that
put it here.

### R1. EFFECT, not substitution

**Question: does the changed code actually take effect at runtime?**

A mechanical substitution can be complete and correct and still change
nothing. Dead code satisfies a literal grep and a green test suite equally
well.

Probes, by shape of change:

- **CSS / styling** — is the selector you changed declared more than once in
  the file or the cascade? Does a later identical or more specific selector
  override the block that was edited? Count the declarations, do not eyeball
  them.
- **Exports and modules** — is the new symbol imported anywhere? Is the old
  path still the one being loaded? Search the import side, not the definition.
- **Branches** — can the new branch be reached? Is the condition ever true on
  any real code path?
- **Config** — does anything read the key that was added? Search the reader.
- **Feature flags** — is the flag set anywhere other than its default, and is
  that default false?
- **Inheritance** — is the method that was changed overridden by the subclass
  that is actually instantiated?
- **Environment** — is the env var now read ever set, in any environment file,
  CI config, or deploy manifest?

**Evidence from PR 33:** the change remapped 123 font-size and 105 font-weight
declarations onto design tokens. Measurement afterwards found **39 selectors
declared more than once** in that single stylesheet, and **7 token
replacements — 5 font-size, 2 font-weight — landed in blocks that a later
identical selector overrides**. Those replacements are inert. The stylesheet
renders identically with or without them. The definition of done tested
mechanical substitution, "no numeric literals remain", not effect.

### R2. GUARDRAIL INTEGRITY

**Question: if the change adds a check, can a careless developer walk straight
past it?**

Whenever the diff adds a lint rule, audit script, schema validation, CI gate,
or a regression test that exists to stop a problem coming back, attack it.

- **Do not run the mutation the brief suggested.** The verifier already ran
  it and it passed. It tells you nothing.
- Ask what the *next most likely* way is that a developer reintroduces this
  problem without meaning to: alternative syntax, a shorthand form, a
  different file extension, a different directory, an equivalent API, a
  generated file, an inline style, a dynamically computed value.
- Then **actually try it**. Write the bypass into a real file, run the check,
  record the exit code, and revert the probe.
- Check the guardrail is wired in at all: is it called by CI, by a pre-commit
  hook, by the build? A check nothing invokes is decoration.

**Evidence from PR 33:** the change added `frontend/scripts/audit-typography.mjs`
to fail the build if a font literal was reintroduced. The verifier was told to
mutation-test it by inserting `font-size: 9px`, did exactly that, got a
non-zero exit, and reported the guardrail real rather than a rubber stamp. But
the script only matches `font-size:` and `font-weight:` declarations.
Appending `.audit-hole-test { font: 600 9px/1.2 Roboto; }` was confirmed
afterwards to leave the audit **exiting 0**. The CSS `font` shorthand walks
straight through it. The verifier tested the mutation it was told to test, not
what an adversary would try. A verifier following a checklist finds only what
the checklist names.

### R3. GENERALISATION GAP

**Question: the brief named one instance of a problem — how many instances are
there?**

Whenever the task, the diff, or a code comment refers to a specific occurrence
of a pattern, stop and count the population.

- Extract the pattern from the named instance.
- Search the whole file, then the module, then the repo.
- Report the count and the locations, not "there may be others".

A brief that says "reconcile the duplicated token block" produces a worker
that reconciles that one block and a verifier that confirms that one block.
Nobody in the chain is asked the obvious next question.

**Evidence from PR 33:** the orchestrator had personally found that
`.iep-dashboard-page` was declared twice with conflicting custom properties,
the later winning, and briefed the worker to reconcile that one block. The
worker did exactly that. The verifier confirmed exactly that. **1 instance was
fixed. 39 duplicated selectors were present in the same file.** Nobody looked
for the other 38.

### R4. DEFINITION OF DONE BLIND SPOTS

**Question: what could be true, and bad, while every stated criterion still
passes?**

Read the definition of done as the artefact under review, not as the standard
you measure against.

- Take each criterion and construct a change that satisfies it and is still
  wrong. If you can construct one, go and check whether the change in front of
  you is that change.
- Look for criteria phrased as absence — "no X remains" — rather than presence
  — "Y now happens". Absence criteria are satisfied by deletion, by comments,
  by dead code, and by moving the problem elsewhere.
- Look for criteria that measure the artefact rather than the behaviour: grep
  counts, file counts, "tests pass", "build succeeds".
- Name the blind spots explicitly in the report, then say for each one whether
  you checked it and what you found.

This is the line that catches the class of defect the other lines have not
been written for yet.

### R5. SCOPE

**Question: what is in the diff that the task did not ask for, and what did
the task ask for that is quietly missing?**

Both directions matter.

- Unrequested: incidental refactors, reformatting, dependency bumps, version
  changes, deleted code that was not in scope, new files nobody asked for.
- Silently missing: a step in the task with no corresponding change in the
  diff, a case handled for one input but not its sibling, the docs, types,
  migrations, or config the change implies but does not include.

---

## Evidence, not opinion

**Every finding carries evidence.**

- A structural claim carries a **file path and line number**.
- A behavioural claim carries **a command that was actually run**, plus its
  **output or exit code**, pasted.

If you can produce neither, the finding is a guess. Drop it, or label it
`UNVERIFIED SUSPICION` and state what would confirm it. Never leave an
unverified claim in the report looking like a measured one.

Where a probe modified a file, say so and confirm you reverted it.

---

## Severity

Every finding gets one of three levels. The orchestrator acts on the level, so
do not blur them.

| Severity | Meaning | Action |
|----------|---------|--------|
| `BLOCKER` | Do not open the PR. The change is inert, bypassable, wrong, or out of scope in a way that matters. | Fix first |
| `SHOULD FIX` | Open the PR, but fix this inside it. | Correction pass |
| `NOTE` | Real, but gates nothing. | Record only |

Number every finding — `F1`, `F2`, ... — so a correction brief can reference
them without quoting them.

---

## Report format

```
REVIEW OF: <task, one line>

F1  BLOCKER  <one-line claim>
    Where:    src/styles/app.css:412-418
    Evidence: $ grep -c '^\.iep-dashboard-page' src/styles/app.css
              2
              The block at :412 is overridden by the identical selector at :980.
    Why it matters: the 5 token replacements in this block are inert.

F2  SHOULD FIX  <one-line claim>
    Where:    scripts/audit-typography.mjs:23
    Evidence: $ printf '.t{font:600 9px/1.2 Roboto;}' >> src/styles/app.css \
                && node scripts/audit-typography.mjs; echo "exit=$?"
              exit=0
              (probe line reverted)
    Why it matters: the guardrail does not catch the shorthand form.

F3  NOTE  <one-line claim>
    Where:    ...
    Evidence: ...

LINES WORKED: R1 effect, R2 guardrail, R3 generalisation, R4 DoD blind spots, R5 scope
DoD BLIND SPOTS NAMED: <the states you constructed, and what you found for each>

REVIEW: BLOCKED
```

The last line is the single verdict. It is exactly one of:

- `REVIEW: CLEAR` — no blockers. The PR may be created. `SHOULD FIX` and
  `NOTE` findings may still be present.
- `REVIEW: BLOCKED` — at least one `BLOCKER`. No PR is created until the
  blockers are corrected.

Nothing follows that line.

**The verdict token is not a grep target — the position is the contract.**
Either token, written literally, must appear exactly once in the whole report:
on the final line, and nowhere else — not in a finding, not in quoted
evidence, not in a worked example, not in prose discussing the convention. A
report whose real verdict is `BLOCKED` must never contain the literal text
`REVIEW: CLEAR` anywhere earlier, or an orchestrator that greps the whole
report for `CLEAR` waves it through. If you need to discuss a verdict inside
the body, describe it — "a clear verdict", "the blocked case" — never write
the literal token there.

An orchestrator reads the verdict by checking the final line only (e.g. `tail
-n 1`), never by grepping the whole report for either token.

---

## Anti-patterns

Each of these has produced a review that looked like work and caught nothing.

- **Do not fix anything.** You review. Correction is a separate dispatch back
  to the implementer. The one exception is a temporary probe file written to
  attack a guardrail, which you revert.
- **Do not re-run the verifier's checks and call it a review.** The tests
  passing is your starting position, not a finding.
- **Do not run the mutation the brief suggested.** It has already passed.
- **Do not report style opinions, naming preferences, formatting, or
  hypothetical future refactors.** Nobody asked, and it buries the real
  findings.
- **Do not pad the report with things that are fine.** A list of everything
  you checked and liked is noise. Report defects and the blind spots you
  named.
- **Do not approve because the tests pass.** That is the exact reasoning that
  let PR 33 through.
- **Do not write "there may be other instances".** Count them.
