#!/usr/bin/env bash
# uninstall.sh — remove the symlinks install.sh created, and nothing else.
#
# A destination is only removed when it is a symlink whose resolved target is
# inside this bundle. Regular files, directories, and symlinks pointing
# somewhere else are reported and left exactly as they are.
#
# usage: ./uninstall.sh [--prefix DIR] [--claude-dir DIR] [--dry-run]
#
#   --prefix DIR      where ccd/ccw/orchestrate-doctor were linked (default: $HOME/bin)
#   --claude-dir DIR  your Claude Code config dir                  (default: $HOME/.claude)
#   --dry-run         print every action, change nothing

set -euo pipefail

# --------------------------------------------------- bundle root (symlink-safe)
resolve_dir() {
  local src="$1" dir target hops=0
  while [ -L "$src" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      printf 'uninstall.sh: symlink cycle (or >40 hops) resolving %s\n' "$1" >&2
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

# fully resolve a path (following a symlink chain) to an absolute physical path
resolve_path() {
  local src="$1" dir target hops=0
  while [ -L "$src" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      printf '%s' "$src"
      return 0
    fi
    dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
    target=$(readlink "$src")
    case "$target" in
      /*) src="$target" ;;
      *)  src="$dir/$target" ;;
    esac
  done
  if dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd); then
    printf '%s/%s' "$dir" "$(basename "$src")"
  else
    printf '%s' "$src"
  fi
}

BUNDLE_ROOT="$(resolve_dir "${BASH_SOURCE[0]}")"

PREFIX="$HOME/bin"
CLAUDE_DIR="$HOME/.claude"
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
usage: ./uninstall.sh [--prefix DIR] [--claude-dir DIR] [--dry-run]

  --prefix DIR      where ccd/ccw/orchestrate-doctor were linked (default: $HOME/bin)
  --claude-dir DIR  your Claude Code config dir                  (default: $HOME/.claude)
  --dry-run         print every action, change nothing
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="${2:-}"; shift 2 ;;
    --claude-dir) CLAUDE_DIR="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage ;;
    *) printf 'uninstall.sh: unknown option %s\n' "$1" >&2; usage ;;
  esac
done

REMOVED=0
KEPT=0
ABSENT=0

unlink_one() {
  local dst="$1" target

  if [[ -L "$dst" ]]; then
    target="$(resolve_path "$dst")"
    case "$target" in
      "$BUNDLE_ROOT"/*)
        if [[ "$DRY_RUN" == 1 ]]; then
          printf 'would remove %s -> %s\n' "$dst" "$target"
        else
          rm -f "$dst"
          printf 'removed      %s -> %s\n' "$dst" "$target"
        fi
        REMOVED=$((REMOVED + 1))
        ;;
      *)
        printf 'left alone   %s is a symlink to %s, outside this bundle\n' "$dst" "$target"
        KEPT=$((KEPT + 1))
        ;;
    esac
    return 0
  fi

  if [[ -e "$dst" ]]; then
    printf 'left alone   %s is not a symlink\n' "$dst"
    KEPT=$((KEPT + 1))
    return 0
  fi

  printf 'not present  %s\n' "$dst"
  ABSENT=$((ABSENT + 1))
  return 0
}

printf 'bundle       %s\n' "$BUNDLE_ROOT"
if [[ "$DRY_RUN" == 1 ]]; then
  printf 'mode         dry run — nothing will be changed\n'
fi
printf '\n'

unlink_one "$PREFIX/ccd"
unlink_one "$PREFIX/ccw"
unlink_one "$PREFIX/orchestrate-doctor"
unlink_one "$CLAUDE_DIR/agents/orchestrator.md"
unlink_one "$CLAUDE_DIR/skills/orchestrate"

printf '\nsummary      %d removed, %d left alone, %d not present\n' "$REMOVED" "$KEPT" "$ABSENT"
printf 'note         the bundle itself at %s is untouched\n' "$BUNDLE_ROOT"
