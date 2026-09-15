#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/herdr-team-pane-role-$$"
FAKE_BIN="$TMP/bin"
LOG="$TMP/herdr.log"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$TMP/copilot/agents"
: >"$TMP/copilot/agents/orchestrator.md"

cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"

case "$1 $2" in
  "session list")
    printf '{"sessions":[{"name":"default","running":true}]}\n'
    ;;
  "agent list")
    printf '{"result":{"agents":[]}}\n'
    ;;
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"p-created"},"tab":{"tab_id":"t-created"}}}\n'
    ;;
  "agent start")
    printf '{"result":{"agent":{"name":"worker"}}}\n'
    ;;
  "pane rename")
    printf '{"result":{"pane":{"pane_id":"%s","label":"%s"}}}\n' "$3" "$4"
    ;;
  "session attach")
    ;;
  *)
    printf 'unexpected herdr call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/copilot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COPILOT_TEST_LOG"
EOF

chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/copilot"

run_ccd_inside_herdr() {
  : >"$LOG"
  HERDR_ENV=1 \
  HERDR_PANE_ID=p-existing \
  HERDR_TEST_LOG="$LOG" \
  COPILOT_TEST_LOG="$TMP/copilot.log" \
  CCD_COPILOT_DIR="$TMP/copilot" \
  PATH="$FAKE_BIN:$PATH" \
    "$ROOT/bin/ccd"

  grep -Fxq 'pane rename p-existing orchestrator' "$LOG"
}

run_ccd_existing_session() {
  : >"$LOG"
  env -u HERDR_ENV -u HERDR_PANE_ID \
    HERDR_TEST_LOG="$LOG" \
    COPILOT_TEST_LOG="$TMP/copilot.log" \
    CCD_COPILOT_DIR="$TMP/copilot" \
    PATH="$FAKE_BIN:$PATH" \
      "$ROOT/bin/ccd"

  grep -Fxq 'pane rename p-created orchestrator' "$LOG"
}

run_ccw_worker() {
  : >"$LOG"
  HERDR_TEST_LOG="$LOG" \
  COPILOT_TEST_LOG="$TMP/copilot.log" \
  PATH="$FAKE_BIN:$PATH" \
    "$ROOT/bin/ccw" worker --role build --cwd "$ROOT" --new-tab workers

  grep -Fxq 'pane rename p-created build' "$LOG"
}

run_ccd_inside_herdr
run_ccd_existing_session
run_ccw_worker

printf 'pane role naming: PASS\n'
