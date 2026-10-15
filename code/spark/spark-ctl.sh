#!/usr/bin/env bash
# spark-ctl.sh — bring GPU containers up and down on the DGX Spark.
#
# One helper for the everyday workflow: launch a full-ML-libs Jupyter Lab,
# open a throwaway GPU dev shell, check status, tail logs, exec in.
# All GPU/UMA run-flags recommended by NVIDIA are baked in.
#
# Commands:
#   jupyter-up [token]   Start Jupyter Lab (detached) from the NGC ML image.
#                        Optional token arg overrides SPARK_JUPYTER_TOKEN.
#   jupyter-down    Stop & remove the Jupyter container.
#   jupyter-url     Print the Lab URL + token again.
#   shell           Interactive GPU dev shell (--rm, removed on exit).
#   run -- CMD...   One-off GPU command in the ML image (--rm).
#   status          List running spark-* containers.
#   logs [name]     Follow logs (default: the Jupyter container).
#   verify          Quick torch/cuda/GB10 check.
#
# Config via env (all optional):
#   SPARK_IMAGE          default nvcr.io/nvidia/pytorch:26.08-py3
#   SPARK_JUPYTER_PORT   default 8888
#   SPARK_JUPYTER_TOKEN  default: random per launch (printed)
#                        (a token passed to 'jupyter-up' takes precedence)
#   SPARK_ROOT           default $HOME/pai/spark  (host data dirs)
#
# Usage:  bash spark-ctl.sh <command> [args]

set -u

IMAGE="${SPARK_IMAGE:-nvcr.io/nvidia/pytorch:26.08-py3}"
PORT="${SPARK_JUPYTER_PORT:-8888}"
ROOT="${SPARK_ROOT:-$HOME/pai/spark}"
JUP_NAME="spark-jupyter"

# NVIDIA-recommended flags for GPU ML containers on Spark (UMA + SHMEM).
GPU_FLAGS=(--gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864)

# Standard host<->container mounts. Everything persists under $SPARK_ROOT.
mounts() {
  mkdir -p "$ROOT"/{models,data,notebooks,work}
  printf '%s\0' \
    -v "$ROOT/notebooks:/workspace/notebooks" \
    -v "$ROOT/data:/workspace/data" \
    -v "$ROOT/models:/workspace/models" \
    -v "$ROOT/work:/workspace/work"
}

# Read NUL-delimited mount args into an array (safe for paths with spaces).
mount_args() { local -n _out="$1"; _out=(); local a; while IFS= read -r -d '' a; do _out+=("$a"); done < <(mounts); }

lan_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

jupyter_up() {
  # Token precedence: CLI arg ($2) > SPARK_JUPYTER_TOKEN env > random.
  local cli_token="${1:-}"
  if docker ps -a --format '{{.Names}}' | grep -qx "$JUP_NAME"; then
    echo "Container '$JUP_NAME' already exists. Use 'jupyter-down' first, or 'jupyter-url'."
    return 1
  fi
  local token; token="${cli_token:-${SPARK_JUPYTER_TOKEN:-$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)}}"
  local -a M; mount_args M
  echo "Starting Jupyter Lab from $IMAGE ..."
  docker run -d --name "$JUP_NAME" "${GPU_FLAGS[@]}" \
    -p "${PORT}:8888" "${M[@]}" -w /workspace \
    "$IMAGE" \
    jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
      --ServerApp.root_dir=/workspace --IdentityProvider.token="$token" >/dev/null || return 1
  local ip; ip="$(lan_ip)"
  echo "Started '$JUP_NAME'."
  echo "  Local : http://localhost:${PORT}/lab?token=${token}"
  echo "  LAN   : http://${ip}:${PORT}/lab?token=${token}"
  echo "  Data  : $ROOT -> /workspace"
  echo "Bring it down with: bash spark-ctl.sh jupyter-down"
}

jupyter_url() {
  docker ps --format '{{.Names}}' | grep -qx "$JUP_NAME" || { echo "'$JUP_NAME' not running."; return 1; }
  docker exec "$JUP_NAME" jupyter server list 2>/dev/null || echo "Jupyter not ready yet; try again shortly."
}

jupyter_down() {
  docker rm -f "$JUP_NAME" >/dev/null 2>&1 && echo "Removed '$JUP_NAME'." || echo "'$JUP_NAME' not present."
}

dev_shell() {
  local -a M; mount_args M
  exec docker run -it --rm --name "spark-shell-$$" "${GPU_FLAGS[@]}" \
    "${M[@]}" -w /workspace "$IMAGE" bash
}

run_once() {
  shift  # drop the leading 'run'
  [ "${1:-}" = "--" ] && shift
  local -a M; mount_args M
  docker run -it --rm "${GPU_FLAGS[@]}" "${M[@]}" -w /workspace "$IMAGE" "$@"
}

status() {
  echo "Running spark-* containers:"
  docker ps --filter 'name=spark-' --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

logs() { docker logs -f "${2:-$JUP_NAME}"; }

verify() {
  docker run --rm "${GPU_FLAGS[@]}" "$IMAGE" \
    python -c "import torch; print('torch', torch.__version__, '| cuda', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0))"
}

# Fail early with a clear message if the Docker socket isn't reachable.
require_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "ERROR: cannot reach the Docker daemon (permission denied)." >&2
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    echo "You're in the 'docker' group, but this shell predates that change." >&2
    echo "Fix: run 'newgrp docker' (this shell) or log out/in, then retry." >&2
  else
    echo "Your user isn't in the 'docker' group. Run recipe 02 first:" >&2
    echo "  sudo usermod -aG docker \$USER && newgrp docker" >&2
  fi
  exit 1
}

case "${1:-}" in
  jupyter-up)   require_docker; jupyter_up "${2:-}" ;;
  jupyter-down) require_docker; jupyter_down ;;
  jupyter-url)  require_docker; jupyter_url ;;
  shell)        require_docker; dev_shell ;;
  run)          require_docker; run_once "$@" ;;
  status)       require_docker; status ;;
  logs)         require_docker; logs "$@" ;;
  verify)       require_docker; verify ;;
  *) sed -n '2,34p' "$0"; exit 1 ;;
esac
