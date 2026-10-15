#!/usr/bin/env bash
# h100-chat.sh — run the single-user chat UI that wraps the vLLM endpoint.
#
# A tiny FastAPI app (../chat/) with SQLite-backed threaded history: create,
# open, rename, delete conversations; streamed replies from whatever model is
# live on :8000 (Qwen/Gemma/…). Runs with --network host so it reaches the
# vLLM endpoint on localhost and binds the chat port directly on the box.
#
# Commands:
#   up           Build the image if missing, then start the app (detached).
#   down         Stop & remove the app container.
#   rebuild      Force a fresh image build (after editing app.py/index.html).
#   logs         Follow the app logs.
#   status       Show the container + its URL.
#   url          Print the local + LAN URLs.
#
# Config via env (all optional) — pipe them in like the other h100-* scripts:
#   H100_CHAT_PORT     default 8080   (clear of 8000 vLLM / 8888 Jupyter / 11434 ollama)
#   H100_CHAT_HOST     default 0.0.0.0 (use 127.0.0.1 to keep it local to the box)
#   H100_CHAT_VLLM     default http://localhost:8000/v1  (endpoint the app calls)
#   H100_CHAT_API_KEY  default h100   (only needed if vLLM was started with --api-key)
#   H100_CHAT_SYSTEM   optional system prompt prepended to every conversation
#   H100_ROOT          default $HOME/h100c  (SQLite DB lives under chat/)
#   CHAT_IMAGE         default h100-chat:latest
#
# Usage:  bash h100-chat.sh <command>

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HERE/../chat" && pwd)"

ROOT="${H100_ROOT:-$HOME/h100c}"
PORT="${H100_CHAT_PORT:-8080}"
HOST="${H100_CHAT_HOST:-0.0.0.0}"
VLLM_BASE="${H100_CHAT_VLLM:-http://localhost:8000/v1}"
API_KEY="${H100_CHAT_API_KEY:-h100}"
SYSTEM="${H100_CHAT_SYSTEM:-}"
IMAGE="${CHAT_IMAGE:-h100-chat:latest}"
NAME="h100-chat"

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

image_exists() { docker image inspect "$IMAGE" >/dev/null 2>&1; }

build() {
  echo "Building $IMAGE from $APP_DIR ..."
  docker build -t "$IMAGE" "$APP_DIR"
}

up() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "Container '$NAME' already exists. Use 'down' first (or 'logs')."
    return 1
  fi
  image_exists || build || return 1
  mkdir -p "$ROOT/chat/db"
  echo "Starting '$NAME' on :$PORT (endpoint $VLLM_BASE) ..."
  # --network host: reach vLLM on localhost:8000 and bind the port on the box.
  docker run -d --name "$NAME" --network host --restart unless-stopped \
    -e CHAT_PORT="$PORT" -e CHAT_HOST="$HOST" \
    -e VLLM_BASE="$VLLM_BASE" -e VLLM_API_KEY="$API_KEY" \
    -e CHAT_SYSTEM="$SYSTEM" -e CHAT_DB=/data/db/chat.db \
    -v "$ROOT/chat:/data" \
    "$IMAGE" >/dev/null || return 1
  url
  echo "Bring it down with: bash h100-chat.sh down"
}

down() {
  docker rm -f "$NAME" >/dev/null 2>&1 && echo "Removed '$NAME'." || echo "'$NAME' not present."
}

rebuild() {
  build || return 1
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "Recreating '$NAME' with the new image ..."
    docker rm -f "$NAME" >/dev/null 2>&1
    up
  fi
}

logs() { docker logs -f "$NAME"; }

status() {
  echo "Chat container:"
  docker ps --filter "name=$NAME" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  url
}

url() {
  local ip; ip="$(lan_ip)"
  echo "  Local : http://localhost:${PORT}/"
  [ "$HOST" = "0.0.0.0" ] && echo "  LAN   : http://${ip}:${PORT}/"
}

require_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "ERROR: cannot reach the Docker daemon (permission denied)." >&2
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    echo "You're in the 'docker' group, but this shell predates that change." >&2
    echo "Fix: run 'newgrp docker' (this shell) or log out/in, then retry." >&2
  else
    echo "Your user isn't in the 'docker' group:" >&2
    echo "  sudo usermod -aG docker \$USER && newgrp docker" >&2
  fi
  exit 1
}

case "${1:-}" in
  up)      require_docker; up ;;
  down)    require_docker; down ;;
  rebuild) require_docker; rebuild ;;
  logs)    require_docker; logs ;;
  status)  require_docker; status ;;
  url)     url ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac
