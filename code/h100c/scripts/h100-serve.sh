#!/usr/bin/env bash
# h100-serve.sh — serve swappable LLMs on the 4x H100 node with an
# OpenAI-compatible API, so models can be consumed from VS Code / any client.
#
# Same idea as the Spark's spark-serve.sh ("stable endpoint, swappable weights"),
# but tuned for THIS box (see ../00-h100-facts.md):
#   - 4x H100 NVL, ~374 GiB total VRAM, native FP8 (Hopper).
#   - NVLink is 2+2 pairs, NOT all-to-all (GPU0-1 and GPU2-3 fast; across = slow).
#     So tensor-parallel is kept inside a pair where possible; big models use
#     TP=2 x pipeline=2 so the heavy all-reduce stays on NVLink.
#   - Port 8000 is free (:11434 belongs to the paused ollama stack).
#
# Commands:
#   vllm-up [model]     Start vLLM serving <model> (default: Qwen). Detached.
#   vllm-down [-f]      Graceful stop (SIGTERM, up to 20s) + remove. -f = SIGKILL.
#   swap <name|repo>    Down + up in one step. Aliases below.
#   vllm-logs           Follow vLLM logs (watch for "Application startup").
#   status              Show running h100-* serving containers + GPU usage.
#   test [port]         Hit the OpenAI /v1/models endpoint (default 8000).
#
# Model aliases (resolve_model):
#   qwen         Qwen/Qwen3-32B                                  (~32B, 1 GPU)
#   gemma        google/gemma-3-27b-it                           (~27B, 1 GPU)
#   mistral      mistralai/Mistral-Small-3.2-24B-Instruct-2506   (~24B, 1 GPU)
#   deepseek     deepseek-ai/DeepSeek-R1-Distill-Llama-70B       (~70B, TP=2)
#   deepseek-32b deepseek-ai/DeepSeek-R1-Distill-Qwen-32B        (~32B, 1 GPU)
#   llama-70b    meta-llama/Llama-3.3-70B-Instruct               (~70B, TP=2)
#   deepseek-flash  deepseek-ai/DeepSeek-V4-Flash  (~291B FP8, TP=4 — ADVANCED)
#   anything else is treated as a literal HF repo id.
#
# Config via env (all optional):
#   H100_MODEL       default Qwen/Qwen3-32B
#   VLLM_IMAGE       default nvcr.io/nvidia/vllm:26.08-py3
#   VLLM_PORT        default 8000
#   H100_GPUS        default all        (e.g. '"device=0,1"' to pin one pair)
#   H100_TP          override tensor-parallel size (default: auto per model)
#   H100_PP          override pipeline-parallel size (default: auto per model)
#   H100_QUANT       pass --quantization <v> (e.g. fp8); auto-set for *-flash
#   H100_ROOT        default $HOME/h100c  (weights cached under models/)
#   HF_TOKEN         Hugging Face token (REQUIRED for gated Llama/Gemma/Qwen).
#   VLLM_TOOL_ARGS   override tool-call flags (default: auto per model).
#   VLLM_REASON_ARGS override reasoning-parser flags (default: auto per model).
#   VLLM_EXTRA_ARGS  extra flags appended to `vllm serve`.
#
# Gated models need their license accepted on Hugging Face + a token:
#   export HF_TOKEN=hf_xxx
#
# Usage:  bash h100-serve.sh <command> [args]

set -u

ROOT="${H100_ROOT:-$HOME/h100c}"
MODEL_DEFAULT="${H100_MODEL:-Qwen/Qwen3-32B}"

VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.08-py3}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_NAME="h100-vllm"
GPUS="${H100_GPUS:-all}"

# NVIDIA-recommended flags for GPU ML/NGC containers. ipc=host gives the large
# /dev/shm NCCL needs for tensor/pipeline parallel across the 4 H100s.
GPU_FLAGS=(--gpus "$GPUS" --ipc=host --ulimit memlock=-1 --ulimit stack=67108864)

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# Friendly alias -> Hugging Face repo id. Unknown values pass through literally.
resolve_model() {
  case "$1" in
    qwen)           echo "Qwen/Qwen3-32B" ;;
    gemma)          echo "google/gemma-3-27b-it" ;;
    gemma-12b)      echo "google/gemma-3-12b-it" ;;
    mistral)        echo "mistralai/Mistral-Small-3.2-24B-Instruct-2506" ;;
    deepseek)       echo "deepseek-ai/DeepSeek-R1-Distill-Llama-70B" ;;
    deepseek-32b)   echo "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B" ;;
    llama-70b)      echo "meta-llama/Llama-3.3-70B-Instruct" ;;
    deepseek-flash) echo "deepseek-ai/DeepSeek-V4-Flash" ;;
    *)              echo "$1" ;;
  esac
}

# vLLM rejects OpenAI tool calls (VS Code agent mode) with HTTP 400 unless started
# with --enable-auto-tool-choice and a model-appropriate --tool-call-parser.
tool_flags_for() {
  case "$1" in
    *DeepSeek-V4*|*deepseek-v4*)        echo "--enable-auto-tool-choice --tool-call-parser deepseek_v3" ;;
    *[Qq]wen3*|*Distill-Qwen*)          echo "--enable-auto-tool-choice --tool-call-parser hermes" ;;
    mistralai/*|*[Mm]istral*)           echo "--enable-auto-tool-choice --tool-call-parser mistral" ;;
    *Llama-3.3*|*Distill-Llama*|*[Ll]lama*) echo "--enable-auto-tool-choice --tool-call-parser llama3_json" ;;
    *) echo "" ;;   # e.g. Gemma-3: no vLLM tool-call parser -> chat/ask only
  esac
}

# R1-style models emit <think>…</think>; a reasoning parser separates that out.
reason_flags_for() {
  case "$1" in
    *DeepSeek-R1*|*Distill*) echo "--reasoning-parser deepseek_r1" ;;
    *[Qq]wen3*)              echo "--reasoning-parser qwen3" ;;
    *) echo "" ;;
  esac
}

# Pick tensor/pipeline parallelism that respects the 2+2 NVLink topology.
# Small (<=34B) -> 1 GPU; ~70B -> TP=2 (one NVLink pair); huge -> TP=2 x PP=2.
parallel_flags_for() {
  local model="$1" tp pp
  if [ -n "${H100_TP:-}" ] || [ -n "${H100_PP:-}" ]; then
    tp="${H100_TP:-1}"; pp="${H100_PP:-1}"
  else
    case "$model" in
      *DeepSeek-V4*|*-Flash|*120[Bb]*|*180[Bb]*) tp=2; pp=2 ;;   # cross-pair big
      *70[Bb]*|*Distill-Llama*|*Llama-3.3*)       tp=2; pp=1 ;;   # one NVLink pair
      *) tp=1; pp=1 ;;                                            # fits on 1 GPU
    esac
  fi
  local out="--tensor-parallel-size $tp"
  [ "$pp" -gt 1 ] && out="$out --pipeline-parallel-size $pp"
  echo "$out"
}

# FP8 by default for the flash-class checkpoints unless caller overrides.
quant_flags_for() {
  local model="$1"
  if [ -n "${H100_QUANT:-}" ]; then echo "--quantization ${H100_QUANT}"; return; fi
  case "$model" in
    *-Flash|*DeepSeek-V4*) echo "--quantization fp8" ;;
    *) echo "" ;;
  esac
}

require_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "ERROR: cannot reach the Docker daemon (permission denied)." >&2
  echo "Add your user to the docker group or run 'newgrp docker', then retry." >&2
  exit 1
}

vllm_up() {
  local raw="${1:-$MODEL_DEFAULT}"
  local model; model="$(resolve_model "$raw")"
  if docker ps -a --format '{{.Names}}' | grep -qx "$VLLM_NAME"; then
    echo "'$VLLM_NAME' already exists. 'vllm-down' first (or 'swap')."; return 1
  fi
  mkdir -p "$ROOT"/{models,data,work}

  local tool_args reason_args par_args quant_args
  tool_args="${VLLM_TOOL_ARGS-$(tool_flags_for "$model")}"
  reason_args="${VLLM_REASON_ARGS-$(reason_flags_for "$model")}"
  par_args="$(parallel_flags_for "$model")"
  quant_args="$(quant_flags_for "$model")"

  echo "Starting vLLM: $model"
  echo "  parallel : $par_args ${quant_args:+($quant_args)}"
  echo "  tools    : ${tool_args:-<none>}"
  echo "  reasoning: ${reason_args:-<none>}"

  # Run as the host user so the weights cache stays host-owned (plain `rm` works,
  # no root-owned files). HOME/caches point at the writable mount since the
  # container's default HOME (/root) isn't writable for a non-root UID.
  # shellcheck disable=SC2086  # intentional word-splitting of flag strings
  docker run -d --name "$VLLM_NAME" "${GPU_FLAGS[@]}" \
    --user "$(id -u):$(id -g)" \
    -p "${VLLM_PORT}:8000" \
    -v "$ROOT/models:/workspace/models" \
    -e HF_HOME=/workspace/models \
    -e HOME=/workspace/models \
    -e XDG_CACHE_HOME=/workspace/models/.cache \
    -e VLLM_CACHE_ROOT=/workspace/models/.cache/vllm \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    "$VLLM_IMAGE" \
    vllm serve "$model" \
      --host 0.0.0.0 --port 8000 \
      $par_args $quant_args $tool_args $reason_args ${VLLM_EXTRA_ARGS:-} >/dev/null || return 1

  local ip; ip="$(lan_ip)"
  echo "Started '$VLLM_NAME'. Weights cache: $ROOT/models"
  echo "  Endpoint (LAN): http://${ip}:${VLLM_PORT}/v1"
  echo "  Follow startup: bash h100-serve.sh vllm-logs   (wait for 'Application startup complete')"
}

vllm_down() {
  if [ "${1:-}" = "-f" ]; then
    docker rm -f "$VLLM_NAME" >/dev/null 2>&1 && echo "Force-removed '$VLLM_NAME'." || echo "'$VLLM_NAME' not present."
    return
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$VLLM_NAME"; then
    echo "Stopping '$VLLM_NAME' gracefully (up to 20s)…"
    docker stop -t 20 "$VLLM_NAME" >/dev/null 2>&1
    docker rm "$VLLM_NAME" >/dev/null 2>&1 && echo "Removed '$VLLM_NAME'."
  else
    echo "'$VLLM_NAME' not present."
  fi
}

swap() {
  [ -n "${1:-}" ] || { echo "usage: swap <alias|repo>"; return 2; }
  vllm_down
  vllm_up "$1"
}

status() {
  echo "Running h100-* serving containers:"
  docker ps --filter 'name=h100-' --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  echo
  echo "GPU usage:"
  nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv 2>/dev/null \
    || echo "  (nvidia-smi unavailable)"
}

test_api() {
  local port="${1:-$VLLM_PORT}"
  curl -fsS "http://localhost:${port}/v1/models" && echo || echo "No response on :${port} (still loading? check vllm-logs)."
}

case "${1:-}" in
  vllm-up)   require_docker; vllm_up "${2:-}" ;;
  vllm-down) require_docker; vllm_down "${2:-}" ;;
  swap)      require_docker; swap "${2:-}" ;;
  vllm-logs) require_docker; docker logs -f "$VLLM_NAME" ;;
  status)    require_docker; status ;;
  test)      test_api "${2:-}" ;;
  *) sed -n '2,46p' "$0"; exit 1 ;;
esac
