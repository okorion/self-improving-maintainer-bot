#!/usr/bin/env bash
set -euo pipefail

scope="${SCOPE:-docs}"
goal="${GOAL:-Improve the repository based on the latest documentation eval signal.}"
sandbox="${SANDBOX:-workspace-write}"

args=(
  -m self_maintainer_bot.cli
  codex-local-loop
  --scope "$scope"
  --goal "$goal"
  --sandbox "$sandbox"
)

if [[ "${EXECUTE:-}" == "1" ]]; then
  args+=(--execute)
fi

if [[ "${API_EVAL:-}" == "1" ]]; then
  args+=(--api-eval)
fi

if [[ -n "${MODEL:-}" ]]; then
  args+=(--model "$MODEL")
fi

if [[ "${SKIP_VERIFY:-}" == "1" ]]; then
  args+=(--skip-verify)
fi

python "${args[@]}"
