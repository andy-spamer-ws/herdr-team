#!/usr/bin/env bash
# uninstall.sh — remove the symlinks install.sh created, and nothing else.
#
# A destination is only removed when it is a symlink whose resolved target is
# inside this bundle. Regular files, directories, and symlinks pointing
# somewhere else are reported and left exactly as they are.
#
# usage: ./uninstall.sh [--prefix DIR] [--copilot-dir DIR] [--dry-run]
#
#   --prefix DIR       where ccd/ccw/orchestrate-doctor were linked (default: $HOME/bin)
#   --copilot-dir DIR  your Copilot CLI config dir                  (default: $HOME/.copilot)
#   --dry-run          print every action, change nothing
#
# The SR addendum block in <copilot-dir>/copilot-instructions.md is removed by
# its BEGIN/END markers. Everything else in that file is preserved, and the
# file is left in place even when the block was the only thing in it.

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
COPILOT_DIR="$HOME/.copilot"
DRY_RUN=0

# Markers must match install.sh and orchestrate-doctor exactly.
ADDENDUM_BEGIN='<!-- BEGIN herdr-team SR addendum (managed) -->'
ADDENDUM_END='<!-- END herdr-team SR addendum (managed) -->'

usage() {
  cat >&2 <<'EOF'
usage: ./uninstall.sh [--prefix DIR] [--copilot-dir DIR] [--dry-run]

  --prefix DIR       where ccd/ccw/orchestrate-doctor were linked (default: $HOME/bin)
  --copilot-dir DIR  your Copilot CLI config dir                  (default: $HOME/.copilot)
  --dry-run          print every action, change nothing
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)      PREFIX="${2:-}"; shift 2 ;;
    --copilot-dir) COPILOT_DIR="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    *) printf 'uninstall.sh: unknown option %s\n' "$1" >&2; usage ;;
  esac
done

case "$COPILOT_DIR" in
  /*) ;;
  *) COPILOT_DIR="$(pwd -P)/$COPILOT_DIR" ;;
esac

LIBRARY_DIR="$COPILOT_DIR/skill-library"
REMOVED=0
KEPT=0
ABSENT=0
FAILED=0

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

remove_addendum() {
  local dst="$COPILOT_DIR/copilot-instructions.md"

  if [[ ! -f "$dst" ]]; then
    printf 'not present  %s\n' "$dst"
    ABSENT=$((ABSENT + 1))
    return 0
  fi

  if ! grep -qF "$ADDENDUM_BEGIN" "$dst"; then
    printf 'left alone   %s has no herdr-team addendum block\n' "$dst"
    KEPT=$((KEPT + 1))
    return 0
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'would remove addendum block from %s\n' "$dst"
    REMOVED=$((REMOVED + 1))
    return 0
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/herdr-team-instructions.XXXXXX")"
  if ! BEGIN_MARK="$ADDENDUM_BEGIN" END_MARK="$ADDENDUM_END" \
       python3 -c '
import os, sys
begin, end = os.environ["BEGIN_MARK"], os.environ["END_MARK"]
out, skipping = [], False
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        if line.strip() == begin:
            skipping = True
            # drop the single blank separator install.sh wrote before the block
            while out and out[-1].strip() == "":
                out.pop()
            continue
        if skipping:
            if line.strip() == end:
                skipping = False
            continue
        out.append(line)
if skipping:
    print("uninstall.sh: no END marker found — leaving file untouched", file=sys.stderr)
    sys.exit(1)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.writelines(out)
' "$dst" "$tmp"; then
    rm -f "$tmp"
    printf 'left alone   %s — addendum block is malformed, remove it by hand\n' "$dst"
    KEPT=$((KEPT + 1))
    return 0
  fi

  cat "$tmp" >"$dst"
  rm -f "$tmp"
  printf 'removed      %s -> addendum block\n' "$dst"
  REMOVED=$((REMOVED + 1))
  return 0
}

unregister_library() {
  local output args
  args=(unregister --library "$LIBRARY_DIR")
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
if [[ "$DRY_RUN" == 1 ]]; then
  printf 'mode         dry run — nothing will be changed\n'
fi
printf '\n'

unlink_one "$PREFIX/ccd"
unlink_one "$PREFIX/ccw"
unlink_one "$PREFIX/orchestrate-doctor"
unlink_one "$COPILOT_DIR/agents/orchestrator.md"
unlink_one "$COPILOT_DIR/agents/pre-pr-reviewer.md"
unlink_one "$COPILOT_DIR/skills/orchestrate"
unlink_one "$COPILOT_DIR/skills/pre-pr-review"
if [[ -d "$LIBRARY_DIR" ]]; then
  unlink_one "$LIBRARY_DIR/agents/orchestrator.md"
  unlink_one "$LIBRARY_DIR/agents/pre-pr-reviewer.md"
  unlink_one "$LIBRARY_DIR/skills/orchestrate"
  unlink_one "$LIBRARY_DIR/skills/pre-pr-review"
  unregister_library || true
fi
remove_addendum

printf '\nsummary      %d removed, %d left alone, %d not present, %d failed\n' "$REMOVED" "$KEPT" "$ABSENT" "$FAILED"
printf 'note         the bundle itself at %s is untouched\n' "$BUNDLE_ROOT"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
