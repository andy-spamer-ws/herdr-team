#!/usr/bin/env python3
"""Tests for bin/outcomes-pane.

outcomes-pane is a thin bash wrapper: it must never reimplement the outcomes
skill's SQLite queries, only shell out to a pinned oc.py and render what comes
back. These tests exercise it as a subprocess against two oc.py doubles:

  - a full stdlib SQLite fake ("fake oc.py") that behaves like the real
    ~/.copilot/skills/outcomes/oc.py closely enough to prove --once rendering,
    database pinning and refresh work end to end, without touching the user's
    real session store;
  - a scripted failing double, to prove failures propagate rather than
    rendering an empty or success-shaped display.

If the real outcomes oc.py is installed on this machine, one additional test
runs against it directly as a light integration check.
"""

from __future__ import annotations

import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTCOMES_PANE = REPO_ROOT / "bin" / "outcomes-pane"

REAL_OC_PY = Path.home() / ".copilot" / "skills" / "outcomes" / "oc.py"

# A minimal stand-in for the outcomes skill's oc.py: same `add`/`check`/
# `status`/`where` surface, same todos table shape, so outcomes-pane's
# subprocess plumbing is exercised faithfully without depending on the real
# skill being installed at a fixed path.
FAKE_OC_PY = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import argparse, os, sqlite3, subprocess, sys
    from pathlib import Path

    def resolve_db():
        v = os.environ.get("OC_DB")
        if not v:
            sys.exit("fake-oc: OC_DB not set")
        return Path(v)

    def conn():
        c = sqlite3.connect(str(resolve_db()))
        c.row_factory = sqlite3.Row
        c.execute(
            "CREATE TABLE IF NOT EXISTS todos (id TEXT PRIMARY KEY, title TEXT,"
            " description TEXT, status TEXT DEFAULT 'pending',"
            " verify_cmd TEXT, expect TEXT, last_evidence TEXT,"
            " verified_at TEXT, created_at TEXT DEFAULT (datetime('now')),"
            " updated_at TEXT DEFAULT (datetime('now')))"
        )
        return c

    def cmd_add(a):
        with conn() as c:
            c.execute(
                "INSERT OR REPLACE INTO todos(id,title,verify_cmd,status)"
                " VALUES(?,?,?,'pending')",
                (a.id, a.title, a.verify),
            )
        return 0

    def cmd_check(a):
        with conn() as c:
            rows = c.execute("SELECT * FROM todos").fetchall()
            for r in rows:
                p = subprocess.run(r["verify_cmd"], shell=True, capture_output=True, text=True)
                ok = p.returncode == 0
                c.execute(
                    "UPDATE todos SET status=?, last_evidence=? WHERE id=?",
                    ("done" if ok else "blocked", f"rc={p.returncode}", r["id"]),
                )
        return 0

    def cmd_status(a):
        with conn() as c:
            rows = c.execute("SELECT * FROM todos ORDER BY created_at").fetchall()
        for r in rows:
            mark = {"done": "[x]", "blocked": "[!]"}.get(r["status"], "[ ]")
            print(f"{mark} {r['id']:<24} {r['title']}")
            if r["last_evidence"]:
                print(f"      {r['last_evidence']}")
        if not rows:
            print("no outcomes declared")
        return 0

    def cmd_where(a):
        print(resolve_db())
        return 0

    def main():
        p = argparse.ArgumentParser()
        s = p.add_subparsers(dest="cmd", required=True)
        ad = s.add_parser("add"); ad.add_argument("id"); ad.add_argument("title")
        ad.add_argument("--verify", required=True); ad.set_defaults(fn=cmd_add)
        ck = s.add_parser("check"); ck.set_defaults(fn=cmd_check)
        st = s.add_parser("status"); st.set_defaults(fn=cmd_status)
        wh = s.add_parser("where"); wh.set_defaults(fn=cmd_where)
        a = p.parse_args()
        sys.exit(a.fn(a))

    if __name__ == "__main__":
        main()
    """
)

# An oc.py double that always fails, to prove outcomes-pane propagates errors
# instead of printing an empty or success-shaped display.
FAILING_OC_PY = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import sys
    sys.stderr.write("fake-oc: simulated failure\\n")
    sys.exit(3)
    """
)

# An oc.py double whose `where` succeeds but whose `status` fails with a
# specific, distinctive exit code. Regression double for the defect where
# outcomes-pane captured $? *after* the `!` negation in `if ! ...; then`,
# so a status exit 3 was reported and propagated as exit 0/1 instead of 3.
STATUS_FAILS_OC_PY = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import sys
    if sys.argv[1] == "where":
        print("/tmp/regression-fake.db")
        sys.exit(0)
    elif sys.argv[1] == "status":
        sys.stderr.write("fake-oc: simulated status failure\\n")
        sys.exit(3)
    sys.exit(1)
    """
)


def run_pane(args, env=None, timeout=10):
    full_env = dict(os.environ)
    full_env.pop("OC_DB", None)
    full_env.pop("OC_PY", None)
    if env:
        full_env.update(env)
    return subprocess.run(
        [str(OUTCOMES_PANE), *args],
        env=full_env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class OutcomesPaneTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="outcomes-pane-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

        self.fake_oc = Path(self.tmp) / "oc.py"
        self.fake_oc.write_text(FAKE_OC_PY, encoding="utf-8")
        self.fake_oc.chmod(0o755)

        self.failing_oc = Path(self.tmp) / "failing_oc.py"
        self.failing_oc.write_text(FAILING_OC_PY, encoding="utf-8")
        self.failing_oc.chmod(0o755)

        self.status_fails_oc = Path(self.tmp) / "status_fails_oc.py"
        self.status_fails_oc.write_text(STATUS_FAILS_OC_PY, encoding="utf-8")
        self.status_fails_oc.chmod(0o755)

        self.db = Path(self.tmp) / "session.db"

    def seed(self, outcome_id="demo-1", title="Demo outcome", verify="true"):
        env = dict(os.environ, OC_DB=str(self.db))
        subprocess.run(
            [sys.executable, str(self.fake_oc), "add", outcome_id, title, "--verify", verify],
            env=env, check=True, capture_output=True, text=True,
        )
        subprocess.run(
            [sys.executable, str(self.fake_oc), "check"],
            env=env, check=True, capture_output=True, text=True,
        )

    # ---------------------------------------------------------- argument validation

    def test_missing_db_and_no_env_fails_explicitly(self):
        result = run_pane(["--once", "--oc-py", str(self.fake_oc)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("no outcomes database pinned", result.stderr)

    def test_missing_db_file_fails_explicitly(self):
        result = run_pane(
            ["--db", str(Path(self.tmp) / "nope.db"), "--once", "--oc-py", str(self.fake_oc)]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("outcomes database not found", result.stderr)
        self.assertIn("nope.db", result.stderr)

    def test_missing_oc_cli_fails_explicitly(self):
        self.seed()
        result = run_pane(
            ["--db", str(self.db), "--once", "--oc-py", str(Path(self.tmp) / "absent.py")]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("outcomes CLI not found", result.stderr)
        self.assertIn("absent.py", result.stderr)

    def test_unknown_option_fails_with_usage(self):
        result = run_pane(["--bogus"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage: outcomes-pane", result.stderr)

    def test_invalid_interval_rejected(self):
        self.seed()
        result = run_pane(
            ["--db", str(self.db), "--oc-py", str(self.fake_oc), "--once", "--interval", "abc"]
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--interval must be a non-negative integer", result.stderr)

    # -------------------------------------------------------------- one-shot rendering

    def test_once_renders_authoritative_status_and_evidence(self):
        self.seed(outcome_id="demo-1", title="Demo outcome", verify="true")
        result = run_pane(["--db", str(self.db), "--oc-py", str(self.fake_oc), "--once"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("demo-1", result.stdout)
        self.assertIn("Demo outcome", result.stdout)
        self.assertIn("[x]", result.stdout)  # done, derived by the fake oc's own check
        self.assertIn("rc=0", result.stdout)  # evidence line, not just a status mark
        self.assertIn(str(self.db), result.stdout)  # `oc.py where` output is shown

    def test_once_reflects_failed_outcome_as_blocked(self):
        self.seed(outcome_id="bad-1", title="Broken outcome", verify="false")
        result = run_pane(["--db", str(self.db), "--oc-py", str(self.fake_oc), "--once"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[!]", result.stdout)
        self.assertIn("bad-1", result.stdout)

    def test_once_with_no_declared_outcomes(self):
        # An empty, freshly created database is a legitimate pinned target —
        # the pane must say so plainly rather than erroring or going blank.
        env = dict(os.environ, OC_DB=str(self.db))
        subprocess.run(
            [sys.executable, str(self.fake_oc), "add", "x", "x", "--verify", "true"],
            env=env, check=True, capture_output=True, text=True,
        )
        subprocess.run(
            [sys.executable, str(self.fake_oc), "check"], env=env, check=True, capture_output=True, text=True,
        )
        # remove the row so status genuinely has nothing to show
        with sqlite3.connect(str(self.db)) as c:
            c.execute("DELETE FROM todos")
        result = run_pane(["--db", str(self.db), "--oc-py", str(self.fake_oc), "--once"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no outcomes declared", result.stdout)

    # ------------------------------------------------------------------- database pinning

    def test_db_flag_overrides_preexisting_oc_db_env(self):
        self.seed(outcome_id="pinned-1", title="Pinned outcome")
        other_db = Path(self.tmp) / "other.db"
        env = dict(os.environ, OC_DB=str(other_db))
        subprocess.run(
            [sys.executable, str(self.fake_oc), "add", "other-1", "Other outcome", "--verify", "true"],
            env={**env}, check=True, capture_output=True, text=True,
        )
        result = run_pane(
            ["--db", str(self.db), "--oc-py", str(self.fake_oc), "--once"],
            env={"OC_DB": str(other_db)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pinned-1", result.stdout)
        self.assertNotIn("other-1", result.stdout)
        self.assertIn(str(self.db), result.stdout)
        self.assertNotIn(str(other_db), result.stdout)

    def test_oc_db_env_used_when_no_db_flag_given(self):
        self.seed(outcome_id="env-pinned", title="Env pinned outcome")
        result = run_pane(
            ["--oc-py", str(self.fake_oc), "--once"], env={"OC_DB": str(self.db)}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("env-pinned", result.stdout)

    # ----------------------------------------------------------------- failure propagation

    def test_failing_oc_cli_propagates_nonzero_and_stderr(self):
        self.seed()  # the db file itself must exist for --db validation to pass
        result = run_pane(["--db", str(self.db), "--once", "--oc-py", str(self.failing_oc)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated failure", result.stderr + result.stdout)
        # never a success-shaped display when the CLI itself failed
        self.assertNotIn("no outcomes declared", result.stdout)

    def test_status_failure_reports_and_propagates_exact_exit_code(self):
        # Regression test: outcomes-pane once captured $? *after* the `!`
        # negation around `status_out=$(oc.py status)`, so it always reported
        # (and propagated) exit 0 or 1, never the real code oc.py exited with.
        self.db.touch()  # --db only needs to exist; this double never reads it
        result = run_pane(
            ["--db", str(self.db), "--once", "--oc-py", str(self.status_fails_oc)]
        )
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("status failed (exit 3)", result.stderr)
        self.assertNotIn("exit 0", result.stderr)
        self.assertIn("simulated status failure", result.stderr)
        # `where` output (rendered before the status call) still shows up —
        # this proves the failure is specific to `status`, not the whole run.
        self.assertIn("/tmp/regression-fake.db", result.stdout)

    # ------------------------------------------------------------------------ refresh loop

    def test_continuous_mode_refreshes_on_interval(self):
        self.seed(outcome_id="loop-1", title="Loop outcome")
        proc = subprocess.Popen(
            [str(OUTCOMES_PANE), "--db", str(self.db), "--oc-py", str(self.fake_oc), "--interval", "0"],
            env={**os.environ, "OC_DB": "", "OC_PY": ""},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(3)
        finally:
            proc.send_signal(signal.SIGTERM)
            try:
                out, err = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                out, err = proc.communicate(timeout=5)
        headers = out.count("outcomes pane —")
        self.assertGreaterEqual(
            headers, 2, f"expected at least 2 refreshes in ~2.5s, got {headers}\nstdout={out}\nstderr={err}"
        )
        self.assertIn("loop-1", out)


@unittest.skipUnless(REAL_OC_PY.is_file(), "real outcomes oc.py not installed on this machine")
class RealOcPyIntegrationTestCase(unittest.TestCase):
    """Light integration check against the actual outcomes skill's oc.py."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="outcomes-pane-real-oc-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.db = Path(self.tmp) / "session.db"
        env = dict(os.environ, OC_DB=str(self.db))
        subprocess.run(
            [sys.executable, str(REAL_OC_PY), "add", "real-1", "Real outcome", "--verify", "true"],
            env=env, check=True, capture_output=True, text=True,
        )
        subprocess.run(
            [sys.executable, str(REAL_OC_PY), "check"], env=env, check=True, capture_output=True, text=True,
        )

    def test_once_against_real_oc_py(self):
        result = run_pane(["--db", str(self.db), "--oc-py", str(REAL_OC_PY), "--once"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("real-1", result.stdout)
        self.assertIn("Real outcome", result.stdout)
        self.assertIn("[x]", result.stdout)


if __name__ == "__main__":
    unittest.main()
