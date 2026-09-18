#!/usr/bin/env bash

set -euo pipefail

omniroute_url="${OMNIROUTE_URL:-http://127.0.0.1:20128}"
omniroute_url="${omniroute_url%/}"
omniroute_env_file="${OMNIROUTE_ENV_FILE:-${HOME}/.omniroute/.env}"
claude_bin="${CLAUDE_BIN:-claude}"

if [[ -z "${OMNIROUTE_API_KEY:-}" && -f "${omniroute_env_file}" ]]; then
  OMNIROUTE_API_KEY="$(sed -n 's/^OMNIROUTE_API_KEY=//p' "${omniroute_env_file}" | head -n 1)"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY#\"}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY%\"}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY#\'}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY%\'}"
fi

: "${OMNIROUTE_API_KEY:?Set OMNIROUTE_API_KEY or add it to ${omniroute_env_file}}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v "${claude_bin}" >/dev/null || {
  echo "Claude Code executable not found: ${claude_bin}" >&2
  exit 1
}

models_json="$(curl -fsS --max-time 20 \
  -H "Authorization: Bearer ${OMNIROUTE_API_KEY}" \
  "${omniroute_url}/v1/models")"

github_claude_models="$(printf '%s' "${models_json}" | jq -r '
  .data[]?.id
  | select(type == "string")
  | select(test("^(gh|github)/claude-(opus|sonnet|haiku)(-|$)"; "i"))
' | sort -u)"

if [[ -z "${github_claude_models}" ]]; then
  echo "No GitHub Copilot Claude models were found at ${omniroute_url}/v1/models" >&2
  exit 1
fi

pick_model() {
  local family="$1"

  printf '%s\n' "${github_claude_models}" | jq -R -s --arg family "${family}" '
    split("\n")
    | map(select(length > 0))
    | map(select(test("^(gh|github)/claude-" + $family + "(-|$)"; "i")))
    | (map(select(startswith("github/"))) as $canonical
       | if ($canonical | length) > 0 then $canonical else . end)
    | if any(.[]; (test("-(low|medium|high|xhigh|ultra)$"; "i") | not))
      then map(select(test("-(low|medium|high|xhigh|ultra)$"; "i") | not))
      else .
      end
    | sort
    | .[-1] // empty
  '
}

opus_model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-$(pick_model opus)}"
sonnet_model="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$(pick_model sonnet)}"
haiku_model="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-$(pick_model haiku)}"

for model in "${opus_model}" "${sonnet_model}" "${haiku_model}"; do
  if [[ -z "${model}" ]]; then
    echo "A GitHub Copilot Claude tier is missing from the model catalog" >&2
    exit 1
  fi
done

printf 'GitHub Copilot Claude models found:\n%s\n\n' "${github_claude_models}"
printf 'Selected Claude tiers:\n  Opus:   %s\n  Sonnet: %s\n  Haiku:  %s\n' \
  "${opus_model}" "${sonnet_model}" "${haiku_model}"

export ANTHROPIC_BASE_URL="${omniroute_url}"
export ANTHROPIC_AUTH_TOKEN="${OMNIROUTE_API_KEY}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${opus_model}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${sonnet_model}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${haiku_model}"
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1"

exec "${claude_bin}" "$@"
