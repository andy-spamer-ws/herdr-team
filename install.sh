#!/usr/bin/env bash
# install.sh — symlink the herdr-team bundle into your PATH and ~/.claude.
#
# Creates five symlinks, all pointing back into this bundle:
#
#   <prefix>/ccd                   -> <bundle>/bin/ccd
#   <prefix>/ccw                   -> <bundle>/bin/ccw
#   <prefix>/orchestrate-doctor    -> <bundle>/bin/orchestrate-doctor
#   <claude-dir>/agents/orchestrator.md -> <bundle>/agents/orchestrator.md
#   <claude-dir>/skills/orchestrate     -> <bundle>/skills/orchestrate
#
# usage: ./install.sh [--prefix DIR] [--claude-dir DIR] [--force] [--dry-run]
#
#   --prefix DIR      where ccd/ccw/orchestrate-doctor go   (default: $HOME/bin)
#   --claude-dir DIR  your Claude Code config dir           (default: $HOME/.claude)
#   --force           replace symlinks that point elsewhere
#   --dry-run         print every action, change nothing
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
CLAUDE_DIR="$HOME/.claude"
FORCE=0
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
usage: ./install.sh [--prefix DIR] [--claude-dir DIR] [--force] [--dry-run]

  --prefix DIR      where ccd/ccw/orchestrate-doctor go   (default: $HOME/bin)
  --claude-dir DIR  your Claude Code config dir           (default: $HOME/.claude)
  --force           replace symlinks that point elsewhere
  --dry-run         print every action, change nothing
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="${2:-}"; shift 2 ;;
    --claude-dir) CLAUDE_DIR="${2:-}"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage ;;
    *) printf 'install.sh: unknown option %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$PREFIX" ]]     || { printf 'install.sh: --prefix needs a value\n' >&2; usage; }
[[ -n "$CLAUDE_DIR" ]] || { printf 'install.sh: --claude-dir needs a value\n' >&2; usage; }

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
  local src="$1" dst="$2" current

  if [[ -L "$dst" ]]; then
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      printf 'ok           %s -> already linked\n' "$dst"
      ALREADY=$((ALREADY + 1))
      return 0
    fi
    if [[ "$FORCE" != 1 ]]; then
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

printf 'bundle       %s\n' "$BUNDLE_ROOT"
printf 'prefix       %s\n' "$PREFIX"
printf 'claude dir   %s\n' "$CLAUDE_DIR"
if [[ "$DRY_RUN" == 1 ]]; then
  printf 'mode         dry run — nothing will be changed\n'
fi
printf '\n'

if ensure_dir "$PREFIX"; then
  link_one "$BUNDLE_ROOT/bin/ccd"                "$PREFIX/ccd"                || true
  link_one "$BUNDLE_ROOT/bin/ccw"                "$PREFIX/ccw"                || true
  link_one "$BUNDLE_ROOT/bin/orchestrate-doctor" "$PREFIX/orchestrate-doctor" || true
fi

if ensure_dir "$CLAUDE_DIR/agents"; then
  link_one "$BUNDLE_ROOT/agents/orchestrator.md" "$CLAUDE_DIR/agents/orchestrator.md" || true
fi

if ensure_dir "$CLAUDE_DIR/skills"; then
  link_one "$BUNDLE_ROOT/skills/orchestrate" "$CLAUDE_DIR/skills/orchestrate" || true
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
