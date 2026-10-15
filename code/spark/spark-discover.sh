#!/usr/bin/env bash
# spark-discover.sh — read-only inventory of a fresh NVIDIA DGX Spark.
#
# Purpose: capture ground-truth state so the recipe folder can be built
# against real facts. SAFE: makes no changes, installs nothing, touches no
# system config. Only writes one report file under the current directory.
#
# Usage:
#   bash spark-discover.sh
# then paste the printed report (or the saved file) back to the assistant.
#
# DGX Spark notes baked in (per NVIDIA docs, verified 2026-09):
#   - Unified Memory Architecture: nvidia-smi shows "Memory-Usage: Not
#     Supported" on purpose; real memory comes from /proc/meminfo.
#   - NVIDIA Container Toolkit is preinstalled; we only *verify* it here.
#   - CUDA line is 13.x on Ubuntu 24.04 base at time of writing.

set -u

REPORT="spark-discovery-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"

# Run a labelled command; record "MISSING" instead of failing the whole run.
section() { printf '\n===== %s =====\n' "$1"; }
run() {
  local desc="$1"; shift
  printf '\n--- %s ---\n$ %s\n' "$desc" "$*"
  if command -v "$1" >/dev/null 2>&1 || [ -e "$1" ]; then
    "$@" 2>&1 || printf '(command exited non-zero)\n'
  else
    printf '(MISSING: %s not found)\n' "$1"
  fi
}

collect() {
  printf 'DGX Spark discovery report\nGenerated: %s\n' "$(date -Is 2>/dev/null || date)"

  section "A. OS & identity"
  run "os-release"    cat /etc/os-release
  run "dgx-release"   cat /etc/dgx-release
  run "kernel/arch"   uname -a
  run "hostnamectl"   hostnamectl
  run "uptime"        uptime

  section "B. CPU"
  run "lscpu"         lscpu

  section "C. Memory (UMA — trust these, not nvidia-smi)"
  run "free"          free -h
  # MemAvailable + SwapFree = practical allocatable memory on Spark's UMA.
  run "meminfo (key)" sh -c "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|HugePages_Total' /proc/meminfo"
  run "swap"          swapon --show

  section "D. GPU / driver / CUDA"
  run "nvidia-smi"        nvidia-smi
  run "nvidia-smi -q mem" sh -c "nvidia-smi -q -d MEMORY 2>&1 | head -40"
  run "nvcc"              nvcc --version
  run "cuda dir"          sh -c "ls -d /usr/local/cuda* 2>/dev/null || echo none"
  run "nvidia devices"    sh -c "ls -la /dev/nvidia* 2>/dev/null || echo none"

  section "E. Storage"
  run "df"            df -hT
  run "lsblk"         lsblk

  section "F. Container runtime (should be preinstalled)"
  run "docker ver"        docker --version
  run "docker info"       sh -c "docker info 2>&1 | grep -Ei 'server version|runtime|cgroup|root dir|storage driver' || echo 'docker info failed (perm? daemon?)'"
  run "nvidia-ctk"        nvidia-ctk --version
  run "daemon.json"       cat /etc/docker/daemon.json
  run "user groups"       id -nG

  section "G. Python & build tooling"
  run "python3"       python3 --version
  run "python3 path"  which python3
  run "pip"           sh -c "python3 -m pip --version 2>&1 || echo 'no pip'"
  run "venv module"   sh -c "python3 -m venv --help >/dev/null 2>&1 && echo 'venv: ok' || echo 'no venv module'"
  run "conda"         conda --version
  run "gcc"           sh -c "gcc --version 2>&1 | head -1 || echo 'no gcc'"
  run "git"           git --version

  section "H. Existing AI stack (avoid reinstalling)"
  run "ollama"        ollama --version
  run "docker images" sh -c "docker images 2>/dev/null | grep -Ei 'nvcr.io|cuda|nemo|triton|ollama|jupyter|vllm|pytorch' || echo 'none / no docker access'"
  run "listeners"     sh -c "ss -tlnp 2>/dev/null | grep -E ':(8888|11434|8000|8080|3000)' || echo 'no relevant listeners'"

  section "END"
  printf 'Report complete.\n'
}

collect | tee "$REPORT"

printf '\n>>> Saved to: %s\n' "$REPORT"
printf '>>> Paste the report above (or the file contents) back to the assistant.\n'
