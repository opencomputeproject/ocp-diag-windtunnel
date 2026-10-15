#!/usr/bin/env bash
# spark-base-setup.sh — make GPU containers usable on a fresh DGX Spark.
#
# What it DOES (idempotent, safe to re-run):
#   1. Adds the current user to the `docker` group (if missing).
#   2. Verifies Docker works; confirms the NVIDIA runtime via a --gpus=all test.
#   3. If the GPU test fails, wires the NVIDIA runtime (nvidia-ctk) and retries.
#   4. Optional: PyTorch-on-GPU test from NGC (heavy pull) with --with-pytorch.
#   5. Creates ~/pai/spark/{models,data,notebooks,work}.
#   6. Saves a report you paste back to the assistant.
#
# CHANGES IT MAKES (all standard DGX Spark setup, logged as they happen):
#   - usermod -aG docker $USER
#   - possibly: nvidia-ctk runtime configure + systemctl restart docker
#   - mkdir under ~/pai/spark
# It does NOT touch driver/CUDA or run apt.
#
# Usage:
#   bash spark-base-setup.sh                # base wiring + light CUDA test
#   bash spark-base-setup.sh --with-pytorch # also pull NGC PyTorch (large)
#
# You may be prompted for your sudo password.

set -u

WITH_PYTORCH=0
[ "${1:-}" = "--with-pytorch" ] && WITH_PYTORCH=1

CUDA_IMAGE="nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04"
PYTORCH_IMAGE="nvcr.io/nvidia/pytorch:26.08-py3"
REPORT="spark-base-setup-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"

log()  { printf '\n[ %s ] %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n===== %s =====\n' "$1"; }

# Run docker in a way that works even before a re-login applies the new group.
# Prefers group-less access; falls back to sudo if the daemon denies us.
DOCKER="docker"
pick_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  elif sg docker -c "docker info" >/dev/null 2>&1; then
    DOCKER="sg docker -c"      # run as: $DOCKER "docker ..."
  elif sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    DOCKER=""
  fi
}
# Unified docker caller respecting the chosen access method.
# For the `sg` path, shell-quote every arg with %q so nested quotes/parens
# (e.g. python -c "...") survive being passed as a single command string.
dock() {
  case "$DOCKER" in
    "sg docker -c")
      local cmd
      cmd=$(printf '%q ' docker "$@")
      sg docker -c "$cmd" ;;
    "sudo docker")  sudo docker "$@" ;;
    "docker")       docker "$@" ;;
    *)              return 127 ;;
  esac
}

run() {
  step "1. Docker group membership"
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    log "User '$USER' already in docker group."
  else
    log "Adding '$USER' to docker group (sudo usermod -aG docker)."
    sudo usermod -aG docker "$USER"
    log "Added. NOTE: a full logout/login is needed for sudoless docker to"
    log "persist; this run uses 'sg docker' / 'sudo' so we can proceed now."
  fi

  step "2. Docker reachability"
  pick_docker
  if [ -z "$DOCKER" ]; then
    log "ERROR: cannot reach the Docker daemon by any method."
    dock version 2>&1 || true
    return 1
  fi
  log "Using docker access method: '$DOCKER'"
  dock version 2>&1 | grep -Ei 'version' | head -8

  step "3. GPU-in-container test (--gpus=all)"
  log "Pulling $CUDA_IMAGE (first time may take a few minutes)..."
  if dock run --rm --gpus=all "$CUDA_IMAGE" nvidia-smi; then
    log "GPU container test PASSED — NVIDIA runtime is wired."
  else
    log "GPU test FAILED. Attempting to register the NVIDIA runtime..."
    step "3b. Configure NVIDIA runtime"
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    log "Runtime configured + docker restarted. Retrying GPU test..."
    pick_docker
    if dock run --rm --gpus=all "$CUDA_IMAGE" nvidia-smi; then
      log "GPU container test PASSED after configuration."
    else
      log "GPU test STILL FAILING — capturing diagnostics for review."
      dock info 2>&1 | grep -Ei 'runtime|error' || true
    fi
  fi

  step "4. Runtime wiring facts"
  dock info 2>&1 | grep -Ei 'Server Version|Runtimes|Default Runtime|Storage Driver|Cgroup' || true
  printf '\n-- /etc/docker/daemon.json --\n'
  cat /etc/docker/daemon.json 2>/dev/null || echo "no daemon.json"

  if [ "$WITH_PYTORCH" -eq 1 ]; then
    step "5. PyTorch-on-GPU test (NGC, large pull)"
    log "Pulling $PYTORCH_IMAGE ..."
    if dock run --rm --gpus=all "$PYTORCH_IMAGE" \
        python -c "import torch; print('torch', torch.__version__, '| cuda', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0))"; then
      log "PyTorch GPU test PASSED."
    else
      log "PyTorch test failed — the image tag may be stale (tags are monthly)."
      log "Report this so the assistant can look up the current aarch64 tag."
    fi
  else
    step "5. PyTorch test skipped"
    log "Re-run with --with-pytorch to pull the NGC PyTorch image and verify."
  fi

  step "6. Working directories"
  mkdir -p "$HOME"/pai/spark/{models,data,notebooks,work}
  log "Ensured: $HOME/pai/spark/{models,data,notebooks,work}"
  ls -la "$HOME/pai/spark"

  step "END"
  log "Base setup complete."
}

run 2>&1 | tee "$REPORT"

printf '\n>>> Saved to: %s\n' "$REPORT"
printf '>>> Paste this report back to the assistant.\n'
if id -nG | tr ' ' '\n' | grep -qx docker && ! docker info >/dev/null 2>&1; then
  printf '>>> Reminder: log out and back in once for sudoless docker to stick.\n'
fi
