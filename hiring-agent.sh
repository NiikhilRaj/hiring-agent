#!/usr/bin/env bash
#
# Run the hiring agent in Docker.
#
#   ./hiring-agent.sh setup                                         pick a provider from providers.json
#   ./hiring-agent.sh batch sheet.xlsx resumes/ --role ROLE [opts]  rank a sheet of applicants
#   ./hiring-agent.sh score resume.pdf --role ROLE                  score a single resume
#   ./hiring-agent.sh score --init-role NAME                        create a new role under roles/
#   ./hiring-agent.sh build                                         rebuild the image
#   ./hiring-agent.sh stop                                          stop the bundled Ollama container
#
# Paths are relative to the folder you run it from; cache/ and scores.csv are
# written there too. roles/ is shared with the container, so role edits apply
# immediately.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE="hiring-agent"
NETWORK="hiring-agent"
OLLAMA_CONTAINER="hiring-agent-ollama"
OLLAMA_VOLUME="hiring-agent-ollama"

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Get it from https://docs.docker.com/get-docker/"
  docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop (or the docker service) and retry."
}

env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true
}

# choose "prompt" "newline separated options" [default] -> echoes the picked option
choose() {
  local prompt="$1" options="$2" default="${3:-1}" count reply
  count="$(printf '%s\n' "$options" | grep -c .)"
  echo "$prompt" >&2
  printf '%s\n' "$options" | awk '{ printf "  %d) %s\n", NR, $0 }' >&2
  while true; do
    read -r -p "Choice [$default]: " reply
    reply="${reply:-$default}"
    if [ "$reply" -ge 1 ] 2>/dev/null && [ "$reply" -le "$count" ]; then
      printf '%s\n' "$options" | sed -n "${reply}p"
      return
    fi
    echo "Please pick a number from 1 to $count." >&2
  done
}

# Read providers.json through the image, so the host needs nothing but Docker.
# providers_json "<python iterable over c>" -> one line per item
providers_json() {
  docker run --rm --entrypoint python "$IMAGE" -c \
    "import json; c = json.load(open('/app/providers.json')); print('\n'.join($1))"
}

build_image() {
  local quiet="${1:-}" out
  if [ "$quiet" = "quiet" ]; then
    out="$(docker build -q -t "$IMAGE" "$SCRIPT_DIR" 2>&1)" || { echo "$out" >&2; die "Docker build failed."; }
  else
    docker build -t "$IMAGE" "$SCRIPT_DIR"
  fi
}

start_bundled_ollama() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

  if ! docker container inspect "$OLLAMA_CONTAINER" >/dev/null 2>&1; then
    info "Starting Ollama container"
    local args=(-d --name "$OLLAMA_CONTAINER" --network "$NETWORK" -v "$OLLAMA_VOLUME:/root/.ollama")
    # Use an NVIDIA GPU when the host has one; fall back to CPU if Docker can't attach it.
    if command -v nvidia-smi >/dev/null 2>&1 && docker run "${args[@]}" --gpus all ollama/ollama >/dev/null 2>&1; then
      :
    else
      docker rm -f "$OLLAMA_CONTAINER" >/dev/null 2>&1 || true
      docker run "${args[@]}" ollama/ollama >/dev/null
    fi
  elif [ "$(docker container inspect -f '{{.State.Running}}' "$OLLAMA_CONTAINER")" != "true" ]; then
    info "Starting Ollama container"
    docker start "$OLLAMA_CONTAINER" >/dev/null
  fi

  local tries=0
  until docker exec "$OLLAMA_CONTAINER" ollama list >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 30 ] && die "Ollama container did not become ready. Check: docker logs $OLLAMA_CONTAINER"
    sleep 1
  done
}

ensure_bundled_model() {
  local model="$1"
  if ! docker exec "$OLLAMA_CONTAINER" ollama show "$model" >/dev/null 2>&1; then
    info "Pulling $model into the Ollama container (first time only)"
    docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
  fi
}

setup() {
  require_docker

  if [ -f "$ENV_FILE" ]; then
    read -r -p "$ENV_FILE already exists. Overwrite it? [y/N]: " reply
    case "$reply" in y|Y|yes|YES) ;; *) echo "Keeping existing settings."; exit 0 ;; esac
  fi

  info "Building the hiring-agent image"
  build_image
  echo

  local provider model key_env="" api_key="" ollama_mode=""
  provider="$(choose "Which provider should score resumes? (from providers.json)" \
    "$(providers_json "c['providers']")")"
  key_env="$(providers_json "[c['providers']['$provider'].get('api_key_env') or '']")"

  echo
  model="$(choose "Model:" "$(providers_json "c['providers']['$provider']['models']")")"

  if [ -n "$key_env" ]; then
    echo
    case "$provider" in
      gemini) echo "Get a key at https://aistudio.google.com/api-keys" ;;
      anthropic) echo "Get a key at https://platform.claude.com/settings/keys (uses Console API credits, not a claude.ai plan)" ;;
    esac
    while [ -z "$api_key" ]; do
      read -r -s -p "$key_env (input hidden): " api_key
      echo
    done
  fi

  if [ "$provider" = "ollama" ]; then
    echo
    local default_mode=2
    [ "$(uname -s)" = "Darwin" ] && default_mode=1
    ollama_mode="$(choose "Where should Ollama run?" \
"On this machine (installed from ollama.com; uses your GPU / Apple Silicon)
Inside Docker (nothing to install; CPU-only on macOS, so much slower)" "$default_mode")"

    case "$ollama_mode" in
      "On this machine"*)
        ollama_mode="host"
        if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
          echo
          echo "Warning: Ollama is not answering on localhost:11434. Install it from https://ollama.com and run 'ollama serve'."
        elif command -v ollama >/dev/null 2>&1 && ! ollama show "$model" >/dev/null 2>&1; then
          info "Pulling $model with your local Ollama"
          ollama pull "$model"
        fi
        if [ "$(uname -s)" = "Linux" ]; then
          echo "Linux note: containers can only reach Ollama if it listens beyond localhost."
          echo "Start it with: OLLAMA_HOST=0.0.0.0 ollama serve"
        fi
        ;;
      *)
        ollama_mode="docker"
        start_bundled_ollama
        ensure_bundled_model "$model"
        ;;
    esac
  fi

  echo
  echo "Optional: a GitHub token raises the GitHub API limit from 60 to 5000 requests/hour."
  echo "Create one (no scopes needed) at https://github.com/settings/tokens. Press Enter to skip."
  local github_token
  read -r -s -p "GitHub token (input hidden): " github_token
  echo

  # Docker's --env-file takes values literally, so they are written unquoted.
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by hiring-agent.sh setup. Rerun setup to change.
LLM_PROVIDER=$provider
DEFAULT_MODEL=$model
GITHUB_TOKEN=$github_token
OLLAMA_MODE=$ollama_mode
EOF
  if [ -n "$key_env" ]; then
    echo "$key_env=$api_key" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"

  echo
  info "Setup complete ($provider, $model). Settings saved to $ENV_FILE"
  echo "Roles available: $(ls "$SCRIPT_DIR/roles" | tr '\n' ' ')"
  echo "Next:"
  echo "  $0 batch applicants.xlsx resumes/ --role <role> -o scores.csv"
  echo "  $0 score resume.pdf --role <role>"
}

abs_path() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd)
  else
    echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  fi
}

run_agent() {
  local script="$1"
  shift
  require_docker
  [ -f "$ENV_FILE" ] || die "Not set up yet. Run: $0 setup"

  build_image quiet

  local docker_args=(
    --rm -i
    --env-file "$ENV_FILE"
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    --add-host=host.docker.internal:host-gateway
    -v "$SCRIPT_DIR/roles:/app/roles"
    -v "$PWD:$PWD" -w "$PWD"
  )
  [ -t 0 ] && [ -t 1 ] && docker_args+=(-t)

  # OLLAMA_BASE_URL is set here rather than in .env so local (non-Docker) runs
  # keep using providers.json's localhost URL.
  if [ "$(env_get LLM_PROVIDER)" = "ollama" ]; then
    if [ "$(env_get OLLAMA_MODE)" = "docker" ]; then
      start_bundled_ollama
      ensure_bundled_model "$(env_get DEFAULT_MODEL)"
      docker_args+=(--network "$NETWORK" -e "OLLAMA_BASE_URL=http://$OLLAMA_CONTAINER:11434/v1")
    else
      docker_args+=(-e "OLLAMA_BASE_URL=http://host.docker.internal:11434/v1")
    fi
  fi

  # Mount any path argument outside the current folder at the same path inside
  # the container, so absolute paths and ../ paths work unchanged.
  local mounted=$'\n'"$PWD"$'\n' arg target
  for arg in "$@"; do
    case "$arg" in -*) continue ;; esac
    if [ -e "$arg" ]; then
      target="$(abs_path "$arg")"
    elif [[ "$arg" == */* ]] && [ -d "$(dirname "$arg")" ]; then
      target="$(abs_path "$(dirname "$arg")")"   # output file that doesn't exist yet
    else
      continue
    fi
    case "$target" in "$PWD"|"$PWD"/*|/) continue ;; esac
    case "$mounted" in *$'\n'"$target"$'\n'*) continue ;; esac
    docker_args+=(-v "$target:$target")
    mounted+="$target"$'\n'
  done

  docker run "${docker_args[@]}" "$IMAGE" "/app/$script" "$@"
}

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  setup) setup ;;
  batch) shift; run_agent batch_score.py "$@" ;;
  score) shift; run_agent score.py "$@" ;;
  build) require_docker; build_image ;;
  stop) require_docker; docker stop "$OLLAMA_CONTAINER" >/dev/null 2>&1 && info "Stopped $OLLAMA_CONTAINER" || echo "Ollama container is not running." ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
