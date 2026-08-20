#!/usr/bin/env bash
# roles.sh — the single place the role-to-model mapping lives.
#
# Sourced by bin/ccw and bin/ccd. Nothing else should hardcode a model name.
#
# Every model ID here was verified against this Copilot CLI install, both by
# the models API and by a live `copilot --model <id> -p` round-trip. Two rules
# came out of that and are load-bearing:
#
#   - `claude-haiku-4.5` rejects `--effort` outright, so it is not used; the
#     cheap role uses `gpt-5.6-luna`, which accepts the full effort ladder.
#   - `--context long_context` roughly doubles the per-token price on the
#     OpenAI models, so only the orchestrator and the escalation role ask for it.
#
# `review` deliberately costs the same as `analyse`. It is the adversarial
# pre-PR pass, and its job is to find defects nobody specified — the same class
# of open-ended work as `analyse`. A cheap model there finds only what it is
# told to look for, which is exactly the failure the stage exists to catch.

# roles_flags <role> — prints the copilot flags for a role, or returns 1.
roles_flags() {
  case "$1" in
    mechanical)   printf -- '--model gpt-5.6-luna --effort low' ;;
    build)        printf -- '--model claude-sonnet-5 --effort medium' ;;
    verify)       printf -- '--model gpt-5.6-terra --effort medium' ;;
    review)       printf -- '--model claude-opus-5 --effort xhigh' ;;
    analyse)      printf -- '--model claude-opus-5 --effort xhigh' ;;
    hard)         printf -- '--model claude-opus-5 --effort max --context long_context' ;;
    orchestrator) printf -- '--model gpt-5.6-sol --effort high --context long_context' ;;
    *) return 1 ;;
  esac
}

# roles_model <role> — prints just the model ID, for reporting.
roles_model() {
  local flags
  flags="$(roles_flags "$1")" || return 1
  printf '%s' "$flags" | awk '{print $2}'
}

# roles_list — the valid role names, pipe separated, for usage strings.
roles_list() {
  printf 'mechanical|build|verify|review|analyse|hard|orchestrator'
}
