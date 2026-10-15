#!/usr/bin/env bash
# install.sh — symlink the herdr-team bundle into your PATH and ~/.copilot.
#
# Creates three command symlinks pointing into this bundle. When the canonical
# skill library exists, the four Copilot artefacts use two symlink hops:
#
#   <prefix>/ccd                   -> <bundle>/bin/ccd
#   <prefix>/ccw                   -> <bundle>/bin/ccw
#   <prefix>/orchestrate-doctor    -> <bundle>/bin/orchestrate-doctor
#   <copilot-dir>/agents/orchestrator.md
#       -> <copilot-dir>/skill-library/agents/orchestrator.md
#       -> <bundle>/agents/orchestrator.md
#   <copilot-dir>/skills/orchestrate
#       -> <copilot-dir>/skill-library/skills/orchestrate
#       -> <bundle>/skills/orchestrate
#
# and writes one managed block:
#
#   <copilot-dir>/copilot-instructions.md   the SR communication addendum
#
# The addendum is a copied block rather than a symlink because Copilot has no
# `--append-system-prompt` and the instructions file is shared with everything
# else you have put in it. It is delimited by BEGIN/END markers so uninstall.sh
# can remove exactly what was added and nothing else.
#
# usage: ./install.sh [--prefix DIR] [--copilot-dir DIR] [--force] [--dry-run]
#
#   --prefix DIR       where ccd/ccw/orchestrate-doctor go   (default: $HOME/bin)
#   --copilot-dir DIR  your Copilot CLI config dir           (default: $HOME/.copilot)
#   --force            replace symlinks that point elsewhere
#   --dry-run          print every action, change nothing
#
# Idempotent: running it twice is a no-op, not an error. An existing regular
# file or directory at a destination is never clobbered, with or without
# --force — the run reports the blocking path and exits non-zero.

set -euo pipefail

# --------------------------------------------------- bundle root (symlink-safe)
resolve_dir() {
  local src="$1" dir target hops=0
  while [ -L "$src" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      printf 'install.sh: symlink cycle (or >40 hops) resolving %s\n' "$1" >&2
      exit 1
    fi
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
    target=$(readlink "$src")
    case "$target" in
      /*) src="$target" ;;
      *)  src="$dir/$target" ;;
    esac
  done
  (cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
}

BUNDLE_ROOT="$(resolve_dir "${BASH_SOURCE[0]}")"

PREFIX="$HOME/bin"
COPILOT_DIR="$HOME/.copilot"
FORCE=0
DRY_RUN=0

# Markers must match uninstall.sh and orchestrate-doctor exactly.
ADDENDUM_BEGIN='<!-- BEGIN herdr-team SR addendum (managed) -->'
ADDENDUM_END='<!-- END herdr-team SR addendum (managed) -->'

usage() {
  cat >&2 <<'EOF'
usage: ./install.sh [--prefix DIR] [--copilot-dir DIR] [--force] [--dry-run]

  --prefix DIR       where ccd/ccw/orchestrate-doctor go   (default: $HOME/bin)
  --copilot-dir DIR  your Copilot CLI config dir           (default: $HOME/.copilot)
  --force            replace symlinks that point elsewhere
  --dry-run          print every action, change nothing
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)      PREFIX="${2:-}"; shift 2 ;;
    --copilot-dir) COPILOT_DIR="${2:-}"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) printf 'install.sh: unknown option %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$PREFIX" ]]      || { printf 'install.sh: --prefix needs a value\n' >&2; usage; }
[[ -n "$COPILOT_DIR" ]] || { printf 'install.sh: --copilot-dir needs a value\n' >&2; usage; }

case "$COPILOT_DIR" in
  /*) ;;
  *) COPILOT_DIR="$(pwd -P)/$COPILOT_DIR" ;;
esac

LIBRARY_DIR="$COPILOT_DIR/skill-library"
LINKED=0
ALREADY=0
BLOCKED=0
FAILED=0

ensure_dir() {
  local d="$1"
  if [[ -d "$d" ]]; then
    return 0
  fi
  if [[ -e "$d" ]]; then
    printf 'BLOCKED  %s exists and is not a directory — move it aside, then rerun\n' "$d"
    BLOCKED=$((BLOCKED + 1))
    return 1
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'would mkdir  %s\n' "$d"
  else
    local err
    if ! err="$(mkdir -p "$d" 2>&1)"; then
      printf 'FAILED       mkdir %s — %s\n' "$d" "$err"
      FAILED=$((FAILED + 1))
      return 1
    fi
    printf 'mkdir        %s\n' "$d"
  fi
  return 0
}

link_one() {
  local src="$1" dst="$2" previous="${3:-}" current

  if [[ -L "$dst" ]]; then
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      printf 'ok           %s -> already linked\n' "$dst"
      ALREADY=$((ALREADY + 1))
      return 0
    fi
    if [[ "$FORCE" != 1 && "$current" != "$previous" ]]; then
      printf 'BLOCKED      %s is a symlink to %s — rerun with --force to replace it\n' "$dst" "$current"
      BLOCKED=$((BLOCKED + 1))
      return 1
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
      printf 'would replace %s -> %s (was %s)\n' "$dst" "$src" "$current"
    else
      local err
      if ! err="$(rm -f "$dst" 2>&1 && ln -s "$src" "$dst" 2>&1)"; then
        printf 'FAILED       %s -> %s — %s\n' "$dst" "$src" "$err"
        FAILED=$((FAILED + 1))
        return 1
      fi
      printf 'replaced     %s -> %s\n' "$dst" "$src"
    fi
    LINKED=$((LINKED + 1))
    return 0
  fi

  if [[ -e "$dst" ]]; then
    printf 'BLOCKED      %s exists and is not a symlink — move it aside, then rerun\n' "$dst"
    BLOCKED=$((BLOCKED + 1))
    return 1
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'would link   %s -> %s\n' "$dst" "$src"
  else
    local err
    if ! err="$(ln -s "$src" "$dst" 2>&1)"; then
      printf 'FAILED       %s -> %s — %s\n' "$dst" "$src" "$err"
      FAILED=$((FAILED + 1))
      return 1
    fi
    printf 'linked       %s -> %s\n' "$dst" "$src"
  fi
  LINKED=$((LINKED + 1))
  return 0
}

can_link() {
  local src="$1" dst="$2" previous="${3:-}" current
  if [[ -L "$dst" ]]; then
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" || "$current" == "$previous" || "$FORCE" == 1 ]]; then
      return 0
    fi
    printf 'BLOCKED      %s is a symlink to %s — rerun with --force to replace it\n' "$dst" "$current"
    BLOCKED=$((BLOCKED + 1))
    return 1
  fi
  if [[ -e "$dst" ]]; then
    printf 'BLOCKED      %s exists and is not a symlink — move it aside, then rerun\n' "$dst"
    BLOCKED=$((BLOCKED + 1))
    return 1
  fi
  return 0
}

preflight_library_links() {
  local blocked=0
  can_link "$BUNDLE_ROOT/agents/orchestrator.md" "$LIBRARY_DIR/agents/orchestrator.md" || blocked=1
  can_link "$BUNDLE_ROOT/agents/pre-pr-reviewer.md" "$LIBRARY_DIR/agents/pre-pr-reviewer.md" || blocked=1
  can_link "$BUNDLE_ROOT/skills/orchestrate" "$LIBRARY_DIR/skills/orchestrate" || blocked=1
  can_link "$BUNDLE_ROOT/skills/pre-pr-review" "$LIBRARY_DIR/skills/pre-pr-review" || blocked=1
  can_link "$LIBRARY_DIR/agents/orchestrator.md" "$COPILOT_DIR/agents/orchestrator.md" \
    "$BUNDLE_ROOT/agents/orchestrator.md" || blocked=1
  can_link "$LIBRARY_DIR/agents/pre-pr-reviewer.md" "$COPILOT_DIR/agents/pre-pr-reviewer.md" \
    "$BUNDLE_ROOT/agents/pre-pr-reviewer.md" || blocked=1
  can_link "$LIBRARY_DIR/skills/orchestrate" "$COPILOT_DIR/skills/orchestrate" \
    "$BUNDLE_ROOT/skills/orchestrate" || blocked=1
  can_link "$LIBRARY_DIR/skills/pre-pr-review" "$COPILOT_DIR/skills/pre-pr-review" \
    "$BUNDLE_ROOT/skills/pre-pr-review" || blocked=1
  return "$blocked"
}

install_addendum() {
  local src="$BUNDLE_ROOT/prompts/sr_opus_5_system_prompt.md"
  local dst="$COPILOT_DIR/copilot-instructions.md"

  if [[ ! -r "$src" ]]; then
    printf 'FAILED       addendum source unreadable at %s\n' "$src"
    FAILED=$((FAILED + 1))
    return 1
  fi

  if [[ -e "$dst" && ! -f "$dst" ]]; then
    printf 'BLOCKED      %s exists and is not a regular file — move it aside, then rerun\n' "$dst"
    BLOCKED=$((BLOCKED + 1))
    return 1
  fi

  if [[ -f "$dst" ]] && grep -qF "$ADDENDUM_BEGIN" "$dst"; then
    printf 'ok           %s -> addendum block already present\n' "$dst"
    ALREADY=$((ALREADY + 1))
    return 0
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'would append addendum block to %s\n' "$dst"
    LINKED=$((LINKED + 1))
    return 0
  fi

  local err
  if ! err="$( { [[ -f "$dst" ]] && printf '\n'
      printf '%s\n' "$ADDENDUM_BEGIN"
      cat "$src"
      # the vendored addendum has no trailing newline, so force one: the END
      # marker must start its own line or uninstall.sh cannot match it
      printf '\n%s\n' "$ADDENDUM_END"; } >>"$dst" 2>&1 )"; then
    printf 'FAILED       append addendum to %s — %s\n' "$dst" "$err"
    FAILED=$((FAILED + 1))
    return 1
  fi
  printf 'appended     %s -> addendum block\n' "$dst"
  LINKED=$((LINKED + 1))
  return 0
}

register_library() {
  local output args
  args=(register --library "$LIBRARY_DIR" --bundle "$BUNDLE_ROOT")
  if [[ "$DRY_RUN" == 1 ]]; then
    args+=(--dry-run)
  fi
  if ! output="$(python3 "$BUNDLE_ROOT/lib/library_registry.py" "${args[@]}" 2>&1)"; then
    printf 'FAILED       update %s/library.json — %s\n' "$LIBRARY_DIR" "$output"
    FAILED=$((FAILED + 1))
    return 1
  fi
  printf '%s\n' "$output"
}

printf 'bundle       %s\n' "$BUNDLE_ROOT"
printf 'prefix       %s\n' "$PREFIX"
printf 'copilot dir  %s\n' "$COPILOT_DIR"
if [[ "$DRY_RUN" == 1 ]]; then
  printf 'mode         dry run — nothing will be changed\n'
fi
printf '\n'

if ensure_dir "$PREFIX"; then
  link_one "$BUNDLE_ROOT/bin/ccd"                "$PREFIX/ccd"                || true
  link_one "$BUNDLE_ROOT/bin/ccw"                "$PREFIX/ccw"                || true
  link_one "$BUNDLE_ROOT/bin/orchestrate-doctor" "$PREFIX/orchestrate-doctor" || true
fi

if [[ -d "$LIBRARY_DIR" ]]; then
  if [[ ! -f "$LIBRARY_DIR/library.json" ]]; then
    printf 'FAILED       %s exists without a readable library.json — repair the skill library, then rerun\n' "$LIBRARY_DIR"
    FAILED=$((FAILED + 1))
  elif ensure_dir "$LIBRARY_DIR/agents" &&
       ensure_dir "$LIBRARY_DIR/skills" &&
       ensure_dir "$COPILOT_DIR/agents" &&
       ensure_dir "$COPILOT_DIR/skills" &&
       preflight_library_links &&
       register_library; then
    link_one "$BUNDLE_ROOT/agents/orchestrator.md" "$LIBRARY_DIR/agents/orchestrator.md" || true
    link_one "$BUNDLE_ROOT/agents/pre-pr-reviewer.md" "$LIBRARY_DIR/agents/pre-pr-reviewer.md" || true
    link_one "$BUNDLE_ROOT/skills/orchestrate" "$LIBRARY_DIR/skills/orchestrate" || true
    link_one "$BUNDLE_ROOT/skills/pre-pr-review" "$LIBRARY_DIR/skills/pre-pr-review" || true

    link_one "$LIBRARY_DIR/agents/orchestrator.md" "$COPILOT_DIR/agents/orchestrator.md" \
      "$BUNDLE_ROOT/agents/orchestrator.md" || true
    link_one "$LIBRARY_DIR/agents/pre-pr-reviewer.md" "$COPILOT_DIR/agents/pre-pr-reviewer.md" \
      "$BUNDLE_ROOT/agents/pre-pr-reviewer.md" || true
    link_one "$LIBRARY_DIR/skills/orchestrate" "$COPILOT_DIR/skills/orchestrate" \
      "$BUNDLE_ROOT/skills/orchestrate" || true
    link_one "$LIBRARY_DIR/skills/pre-pr-review" "$COPILOT_DIR/skills/pre-pr-review" \
      "$BUNDLE_ROOT/skills/pre-pr-review" || true
  fi
else
  printf 'WARN         %s not found — linking Copilot artefacts directly; install librarian to enable discovery\n' "$LIBRARY_DIR"
  if ensure_dir "$COPILOT_DIR/agents"; then
    link_one "$BUNDLE_ROOT/agents/orchestrator.md" "$COPILOT_DIR/agents/orchestrator.md" || true
    link_one "$BUNDLE_ROOT/agents/pre-pr-reviewer.md" "$COPILOT_DIR/agents/pre-pr-reviewer.md" || true
  fi
  if ensure_dir "$COPILOT_DIR/skills"; then
    link_one "$BUNDLE_ROOT/skills/orchestrate" "$COPILOT_DIR/skills/orchestrate" || true
    link_one "$BUNDLE_ROOT/skills/pre-pr-review" "$COPILOT_DIR/skills/pre-pr-review" || true
  fi
fi

if ensure_dir "$COPILOT_DIR"; then
  install_addendum || true
fi

printf '\nsummary      %d linked, %d already correct, %d blocked, %d failed\n' "$LINKED" "$ALREADY" "$BLOCKED" "$FAILED"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) printf 'note         %s is not on your PATH — add it to your shell profile\n' "$PREFIX" ;;
esac

if [[ "$BLOCKED" -gt 0 || "$FAILED" -gt 0 ]]; then
  if [[ "$LINKED" -gt 0 ]]; then
    printf 'state        some links were created and some were not — rerunning after clearing the blockers above is safe, install.sh is idempotent\n'
  else
    printf 'state        nothing was installed — rerunning after clearing the blockers above is safe, install.sh is idempotent\n'
  fi
  printf 'next         clear the BLOCKED/FAILED paths above, then rerun ./install.sh\n'
  exit 1
fi

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'next         rerun without --dry-run to apply, then run orchestrate-doctor\n'
else
  printf 'next         run orchestrate-doctor to confirm the install\n'
fi
