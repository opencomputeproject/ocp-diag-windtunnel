#!/usr/bin/env bash
# spark-serve.sh — serve swappable LLMs on the DGX Spark with an
# OpenAI-compatible API, so models can be consumed from VS Code / any client.
#
# Two backends, same "stable endpoint, swappable weights" idea:
#   vLLM   (primary) — NGC container, OpenAI API on :8000. Best throughput.
#   Ollama (option)  — quick GGUF pulls, OpenAI-compat API on :11434.
#
# Commands:
#   vllm-up [model]     Start vLLM serving <model> (default: Gemma). Detached.
#   vllm-down [-f]      Graceful stop (SIGTERM, up to 20s) + remove. -f = SIGKILL.
#   swap <name|repo>    Down + up in one step. Aliases: gemma, gemma-12b, qwen.
#                       Anything else is treated as a literal HF repo id.
#   vllm-logs           Follow vLLM logs (watch for "Application startup").
#   ollama-up           Start the Ollama server (detached).
#   ollama-pull <name>  Pull a model into Ollama (e.g. gemma3:27b).
#   ollama-run <name>   Interactive chat via Ollama.
#   ollama-down         Stop & remove the Ollama container.
#   status              Show running spark-* serving containers.
#   test [port]         Hit the OpenAI /v1/models endpoint (default 8000).
#
# Config via env (all optional):
#   SPARK_MODEL          default google/gemma-3-27b-it   (vLLM HF repo id)
#   VLLM_IMAGE           default nvcr.io/nvidia/vllm:26.08-py3
#   VLLM_PORT            default 8000
#   OLLAMA_IMAGE         default ollama/ollama:latest
#   OLLAMA_PORT          default 11434
#   SPARK_ROOT           default $HOME/pai/spark
#   HF_TOKEN             Hugging Face token (REQUIRED for gated Gemma/Qwen).
#   VLLM_TOOL_ARGS       override tool-call flags (default: auto per model).
#                        Set to "" to disable tool calling.
#   VLLM_EXTRA_ARGS      extra flags appended to `vllm serve`.
#
# Gated models: Gemma and some Qwen weights require accepting the license on
# Hugging Face and a token. Export it first (never commit it):
#   export HF_TOKEN=hf_xxx
#
# Usage:  bash spark-serve.sh <command> [args]

set -u

ROOT="${SPARK_ROOT:-$HOME/pai/spark}"
MODEL_DEFAULT="${SPARK_MODEL:-google/gemma-3-27b-it}"

VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.08-py3}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_NAME="spark-vllm"

OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_NAME="spark-ollama"

# NVIDIA-recommended flags for GPU ML containers on Spark (UMA + SHMEM).
GPU_FLAGS=(--gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864)

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# vLLM rejects OpenAI tool calls (VS Code agent mode) with HTTP 400 unless started
# with --enable-auto-tool-choice and a model-appropriate --tool-call-parser.
# Emit sane defaults per model; override/disable with VLLM_TOOL_ARGS.
tool_flags_for() {
  case "$1" in
    Qwen/Qwen3*|*[Qq]wen3*) echo "--enable-auto-tool-choice --tool-call-parser hermes" ;;
    mistralai/*|*[Mm]istral*) echo "--enable-auto-tool-choice --tool-call-parser mistral" ;;
    *) echo "" ;;   # e.g. Gemma-3: no vLLM tool-call parser -> chat/ask only
  esac
}

require_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "ERROR: cannot reach the Docker daemon (permission denied)." >&2
  echo "Run 'newgrp docker' or log out/in, then retry (see recipe 02)." >&2
  exit 1
}

vllm_up() {
  local model="${1:-$MODEL_DEFAULT}"
  if docker ps -a --format '{{.Names}}' | grep -qx "$VLLM_NAME"; then
    echo "'$VLLM_NAME' already exists. 'vllm-down' first."; return 1
  fi
  if [ -z "${HF_TOKEN:-}" ]; then
    echo "WARNING: HF_TOKEN not set — gated models (Gemma/Qwen) will fail to download."
    echo "  export HF_TOKEN=hf_xxx   then retry."
  fi
  mkdir -p "$ROOT/models"
  local tool_args="${VLLM_TOOL_ARGS-$(tool_flags_for "$model")}"
  echo "Starting vLLM ($VLLM_IMAGE) serving '$model' ..."
  [ -n "$tool_args" ] && echo "  Tool calling    : $tool_args"
  # HF_HOME points the weight cache at the persistent host models dir.
  # gpu-memory-utilization is set explicitly: Spark's UMA under-reports free
  # GPU memory via cudaMemGetInfo, so we tell vLLM how much to use.
  docker run -d --name "$VLLM_NAME" "${GPU_FLAGS[@]}" \
    -p "${VLLM_PORT}:8000" \
    -v "$ROOT/models:/workspace/models" \
    -e HF_HOME=/workspace/models \
    -e HUGGING_FACE_HUB_TOKEN="${HF_TOKEN:-}" \
    "$VLLM_IMAGE" \
    vllm serve "$model" --host 0.0.0.0 --port 8000 \
      --gpu-memory-utilization 0.90 ${tool_args} ${VLLM_EXTRA_ARGS:-} >/dev/null || return 1
  local ip; ip="$(lan_ip)"
  echo "Started '$VLLM_NAME' (first run downloads weights — watch 'vllm-logs')."
  echo "  OpenAI base URL : http://${ip}:${VLLM_PORT}/v1"
  echo "  Model id        : $model"
  echo "  Ready when logs show: 'Application startup complete'."
  echo "Down with: bash spark-serve.sh vllm-down"
}

# Graceful by default: SIGTERM (up to 20s) then remove. `vllm-down -f` = SIGKILL.
vllm_down() {
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$VLLM_NAME"; then
    echo "'$VLLM_NAME' not present."; return 0
  fi
  if [ "${1:-}" = "-f" ]; then
    docker rm -f "$VLLM_NAME" >/dev/null 2>&1 && echo "Force-removed '$VLLM_NAME'."
  else
    echo "Stopping '$VLLM_NAME' gracefully (SIGTERM, up to 20s) ..."
    docker stop -t 20 "$VLLM_NAME" >/dev/null 2>&1
    docker rm "$VLLM_NAME" >/dev/null 2>&1 && echo "Removed '$VLLM_NAME'."
  fi
}
vllm_logs() { docker logs -f "$VLLM_NAME"; }

# Map a short alias to a full HF repo id; pass through anything else literally.
resolve_model() {
  case "${1:?model name or alias}" in
    gemma)     echo "google/gemma-3-27b-it" ;;
    gemma-12b) echo "google/gemma-3-12b-it" ;;
    qwen)      echo "Qwen/Qwen3-32B" ;;
    *)         echo "$1" ;;
  esac
}

vllm_swap() {
  local model; model="$(resolve_model "${1:?usage: swap <gemma|gemma-12b|qwen|repo-id>}")"
  echo "Swapping vLLM to '$model' ..."
  vllm_down
  vllm_up "$model" || return 1
  echo "Follow load with: bash spark-serve.sh vllm-logs"
}

ollama_up() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$OLLAMA_NAME"; then
    echo "'$OLLAMA_NAME' already exists. 'ollama-down' first."; return 1
  fi
  mkdir -p "$ROOT/models/ollama"
  echo "Starting Ollama ($OLLAMA_IMAGE) ..."
  docker run -d --name "$OLLAMA_NAME" "${GPU_FLAGS[@]}" \
    -p "${OLLAMA_PORT}:11434" \
    -v "$ROOT/models/ollama:/root/.ollama" \
    "$OLLAMA_IMAGE" >/dev/null || return 1
  local ip; ip="$(lan_ip)"
  echo "Started '$OLLAMA_NAME'."
  echo "  OpenAI base URL : http://${ip}:${OLLAMA_PORT}/v1"
  echo "  Pull a model    : bash spark-serve.sh ollama-pull gemma3:27b"
}

ollama_pull() { docker exec -it "$OLLAMA_NAME" ollama pull "${1:?model name, e.g. gemma3:27b}"; }
ollama_run()  { docker exec -it "$OLLAMA_NAME" ollama run  "${1:?model name, e.g. gemma3:27b}"; }
ollama_down() { docker rm -f "$OLLAMA_NAME" >/dev/null 2>&1 && echo "Removed '$OLLAMA_NAME'." || echo "'$OLLAMA_NAME' not present."; }

status() {
  echo "Running spark-* serving containers:"
  docker ps --filter 'name=spark-vllm' --filter 'name=spark-ollama' \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

test_endpoint() {
  local port="${1:-$VLLM_PORT}"
  echo "GET http://localhost:${port}/v1/models"
  curl -fsS "http://localhost:${port}/v1/models" && echo || echo "(no response — still loading, or wrong port?)"
}

case "${1:-}" in
  vllm-up)     require_docker; vllm_up "${2:-}" ;;
  vllm-down)   require_docker; vllm_down "${2:-}" ;;
  swap)        require_docker; vllm_swap "${2:-}" ;;
  vllm-logs)   require_docker; vllm_logs ;;
  ollama-up)   require_docker; ollama_up ;;
  ollama-pull) require_docker; ollama_pull "${2:-}" ;;
  ollama-run)  require_docker; ollama_run "${2:-}" ;;
  ollama-down) require_docker; ollama_down ;;
  status)      require_docker; status ;;
  test)        test_endpoint "${2:-}" ;;
  *) sed -n '2,40p' "$0"; exit 1 ;;
esac
