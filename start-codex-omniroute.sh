#!/usr/bin/env bash

set -euo pipefail

omniroute_url="${OMNIROUTE_URL:-http://127.0.0.1:20128}"
omniroute_url="${omniroute_url%/}"
omniroute_url="${omniroute_url%/v1}"
omniroute_env_file="${OMNIROUTE_ENV_FILE:-${HOME}/.omniroute/.env}"
codex_bin="${CODEX_BIN:-codex}"
codex_model="${CODEX_MODEL:-}"
list_models=false
codex_args=()

if [[ -z "${OMNIROUTE_API_KEY:-}" && -f "${omniroute_env_file}" ]]; then
  OMNIROUTE_API_KEY="$(sed -n 's/^OMNIROUTE_API_KEY=//p' "${omniroute_env_file}" | head -n 1)"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY#\"}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY%\"}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY#\'}"
  OMNIROUTE_API_KEY="${OMNIROUTE_API_KEY%\'}"
fi

usage() {
  cat <<'EOF'
Usage: start-codex-omniroute.sh [options] [codex arguments]

Starts Codex with an OmniRoute provider injected through -c flags. No Codex
configuration file is modified.

Options:
  --model MODEL       Use MODEL and inject it with -c model=...
  --list-models       Fetch and print the live OmniRoute model catalog, then exit
  -h, --help          Show this help

Environment:
  OMNIROUTE_URL       OmniRoute root URL (default: http://127.0.0.1:20128)
  OMNIROUTE_API_KEY   API key, or OMNIROUTE_ENV_FILE may provide it
  OMNIROUTE_ENV_FILE  Environment file (default: ~/.omniroute/.env)
  CODEX_MODEL         Default model; --model takes precedence
  CODEX_BIN           Codex executable (default: codex)
EOF
}

while (($# > 0)); do
  case "$1" in
    --model|-m)
      if (($# < 2)); then
        echo "--model requires a model id" >&2
        exit 2
      fi
      codex_model="$2"
      shift 2
      ;;
    --model=*)
      codex_model="${1#--model=}"
      shift
      ;;
    --list-models)
      list_models=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      codex_args+=("$@")
      break
      ;;
    *)
      codex_args+=("$1")
      shift
      ;;
  esac
done

: "${OMNIROUTE_API_KEY:?Set OMNIROUTE_API_KEY or add it to ${omniroute_env_file}}"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v "${codex_bin}" >/dev/null || {
  echo "Codex executable not found: ${codex_bin}" >&2
  exit 1
}

models_json="$(curl -fsS --max-time 20 \
  -H "Authorization: Bearer ${OMNIROUTE_API_KEY}" \
  "${omniroute_url}/v1/models")"

model_ids="$(printf '%s' "${models_json}" | jq -r '
  .data[]?.id
  | select(type == "string")
' | sort -u)"

if [[ -z "${model_ids}" ]]; then
  echo "No models were returned by ${omniroute_url}/v1/models" >&2
  exit 1
fi

model_count="$(printf '%s\n' "${model_ids}" | awk 'NF { count++ } END { print count + 0 }')"
echo "OmniRoute: ${omniroute_url} (${model_count} models available)"

if [[ "${list_models}" == true ]]; then
  printf '%s\n' "${model_ids}"
  exit 0
fi

if [[ -n "${codex_model}" ]]; then
  if ! printf '%s\n' "${model_ids}" | grep -Fqx -- "${codex_model}"; then
    echo "Model is not present in the OmniRoute catalog: ${codex_model}" >&2
    echo "Run $0 --list-models or choose another model with --model" >&2
    exit 1
  fi
  echo "Codex model: ${codex_model}"
else
  echo "Codex model: using Codex's existing/default model"
  echo "Choose a live model explicitly with --model MODEL or CODEX_MODEL=MODEL"
fi

toml_string() {
  jq -Rn --arg value "$1" '$value'
}

provider_args=(
  -c "model_provider=$(toml_string omniroute)"
  -c "model_providers.omniroute.name=$(toml_string OmniRoute)"
  -c "model_providers.omniroute.base_url=$(toml_string "${omniroute_url}/v1")"
  -c "model_providers.omniroute.env_key=$(toml_string OMNIROUTE_API_KEY)"
  -c "model_providers.omniroute.wire_api=$(toml_string responses)"
  -c "model_providers.omniroute.requires_openai_auth=false"
  # OmniRoute converts Codex's web_search tool to a non-streaming response for
  # Copilot, which breaks Codex's Responses streaming protocol. Keep it disabled
  # for this temporary provider override; the user's Codex config is unchanged.
  -c "web_search=$(toml_string disabled)"
)

if [[ -n "${codex_model}" ]]; then
  provider_args+=(
    -c "model=$(toml_string "${codex_model}")"
  )
fi

export OMNIROUTE_API_KEY
exec "${codex_bin}" "${provider_args[@]}" "${codex_args[@]}"
