#!/usr/bin/env bash

set -euo pipefail

repo_url="${OMNIROUTE_REPO_URL:-https://github.com/diegosouzapw/OmniRoute.git}"
source_branch="${OMNIROUTE_BRANCH:-${OMNIROUTE_REF:-release/v3.8.51}}"
image_tag="${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:3.8.51-local}"
build_platform="${OMNIROUTE_PLATFORM:-linux/arm64}"
build_target="${OMNIROUTE_BUILD_TARGET:-runner-base}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compose_env_file="${OMNIROUTE_COMPOSE_ENV_FILE:-${script_dir}/.env}"
no_cache=false

usage() {
  cat <<'EOF'
Usage: build-omniroute-3.8.51.sh [options]

Downloads the OmniRoute source, builds the official Docker runner, and loads
the resulting image into Docker. It does not start Docker Compose.

Options:
  --branch BRANCH    Git branch to build (default: release/v3.8.51)
  --ref REF          Alias for --branch
  --platform VALUE   Docker platform (default: linux/arm64)
  --tag IMAGE        Local image tag (default: diegosouzapw/omniroute:3.8.51-local)
  --target TARGET    Docker target (default: runner-base)
  --env-file FILE    Compose env file to update (default: .env next to this script)
  --no-cache         Build without Docker's layer cache
  -h, --help         Show this help

Environment overrides:
  OMNIROUTE_REPO_URL, OMNIROUTE_BRANCH, OMNIROUTE_PLATFORM,
  OMNIROUTE_IMAGE, OMNIROUTE_BUILD_TARGET, OMNIROUTE_COMPOSE_ENV_FILE
EOF
}

while (($# > 0)); do
  case "$1" in
    --branch|--ref)
      source_branch="${2:?$1 requires a Git branch}"
      shift 2
      ;;
    --platform)
      build_platform="${2:?--platform requires a Docker platform}"
      shift 2
      ;;
    --tag)
      image_tag="${2:?--tag requires an image tag}"
      shift 2
      ;;
    --target)
      build_target="${2:?--target requires a Docker target}"
      shift 2
      ;;
    --env-file)
      compose_env_file="${2:?--env-file requires a Compose env file}"
      shift 2
      ;;
    --no-cache)
      no_cache=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${compose_env_file}" ]]; then
  echo "Compose env file not found: ${compose_env_file}" >&2
  echo "Use --env-file FILE or create the file before building." >&2
  exit 1
fi

compose_image_repository="diegosouzapw/omniroute"
case "${image_tag}" in
  "${compose_image_repository}:"*)
    image_version="${image_tag#${compose_image_repository}:}"
    ;;
  *)
    echo "Image tag must use ${compose_image_repository}:VERSION so Compose can use it via OMNIROUTE_VERSION." >&2
    exit 1
    ;;
esac

if [[ -z "${image_version}" ]]; then
  echo "The image tag must include a non-empty version." >&2
  exit 1
fi

update_compose_env() {
  local env_file="$1"
  local version="$2"
  local env_dir
  local env_name
  local temp_file

  env_dir="$(dirname -- "${env_file}")"
  env_name="$(basename -- "${env_file}")"
  temp_file="$(mktemp "${env_dir}/.${env_name}.XXXXXX")"

  if ! awk -v version="${version}" '
    BEGIN { updated = 0 }
    /^[[:space:]]*OMNIROUTE_VERSION[[:space:]]*=/ {
      print "OMNIROUTE_VERSION=" version
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) print "OMNIROUTE_VERSION=" version
    }
  ' "${env_file}" > "${temp_file}"; then
    rm -f -- "${temp_file}"
    return 1
  fi

  chmod 600 "${temp_file}"
  mv -f -- "${temp_file}" "${env_file}"
}

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker buildx version >/dev/null || {
  echo "Docker Buildx is required" >&2
  exit 1
}

source_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "${source_dir}"
}
trap cleanup EXIT

printf 'Downloading OmniRoute branch %s...\n' "${source_branch}"
git -c advice.detachedHead=false clone \
  --depth 1 \
  --branch "${source_branch}" \
  "${repo_url}" \
  "${source_dir}/OmniRoute"

build_args=(
  docker buildx build
  --platform "${build_platform}"
  --target "${build_target}"
  --tag "${image_tag}"
  --load
)

if [[ "${no_cache}" == true ]]; then
  build_args+=(--no-cache)
fi

printf 'Building %s for %s...\n' "${image_tag}" "${build_platform}"
"${build_args[@]}" "${source_dir}/OmniRoute"

docker image inspect "${image_tag}" \
  --format 'Built {{.RepoTags}} ({{.Os}}/{{.Architecture}})'

update_compose_env "${compose_env_file}" "${image_version}"

cat <<EOF

Image ready: ${image_tag}
Updated ${compose_env_file}: OMNIROUTE_VERSION=${image_version}

Then start only OmniRoute when you are ready:
  docker compose up -d --no-deps --force-recreate omniroute
EOF
