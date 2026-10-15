#!/usr/bin/env bash
# h100-discover.sh — read-only inventory of a 4x NVIDIA H100 cluster/node.
#
# Purpose: capture ground-truth state so the h100c recipe folder can be built
# against real facts. SAFE: makes no changes, installs nothing, touches no
# system config. Only writes one report file under the current directory.
#
# Usage:
#   bash h100-discover.sh
# then paste the printed report (or the saved file) back to the assistant.
#
# H100 cluster notes (differs from DGX Spark's UMA single-chip):
#   - Each H100 has DEDICATED HBM (80GB SXM/PCIe or 94GB NVL); nvidia-smi
#     memory IS reported here (unlike Spark). 4x80 = 320GB, 4x94 = 376GB VRAM.
#   - Multi-GPU: NVLink/NVSwitch topology drives tensor-parallel serving.
#     `nvidia-smi topo -m` and nvlink status matter for big-model throughput.
#   - May use NVSwitch + nvidia-fabricmanager (must be running for NVLink).
#   - InfiniBand/RDMA may be present for multi-node; we only inventory it here.
#   - MIG may be enabled and would carve GPUs into slices — detect it.

set -u

REPORT="h100-discovery-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt"

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
  printf 'H100 cluster discovery report\nGenerated: %s\n' "$(date -Is 2>/dev/null || date)"

  section "A. OS & identity"
  run "os-release"    cat /etc/os-release
  run "dgx-release"   sh -c "cat /etc/dgx-release 2>/dev/null || echo '(not a DGX image)'"
  run "kernel/arch"   uname -a
  run "hostnamectl"   hostnamectl
  run "uptime"        uptime
  run "virt/bare"     sh -c "systemd-detect-virt 2>/dev/null || echo unknown"

  section "B. CPU"
  run "lscpu"         lscpu
  run "numa"          sh -c "lscpu | grep -i numa || echo 'no NUMA info'"

  section "C. System memory"
  run "free"          free -h
  run "meminfo (key)" sh -c "grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree|HugePages_Total' /proc/meminfo"
  run "swap"          swapon --show

  section "D. GPUs / driver / CUDA (dedicated HBM — trust nvidia-smi here)"
  run "nvidia-smi"        nvidia-smi
  run "gpu list"          sh -c "nvidia-smi --query-gpu=index,name,memory.total,memory.used,compute_mode,mig.mode.current,power.limit --format=csv"
  run "gpu count"         sh -c "nvidia-smi -L | wc -l; nvidia-smi -L"
  run "ecc"               sh -c "nvidia-smi --query-gpu=index,ecc.mode.current,ecc.errors.uncorrected.aggregate.total --format=csv 2>&1 | head -10"
  run "nvcc"              nvcc --version
  run "cuda dir"          sh -c "ls -d /usr/local/cuda* 2>/dev/null || echo none"
  run "nvidia devices"    sh -c "ls -la /dev/nvidia* 2>/dev/null || echo none"

  section "E. Multi-GPU interconnect (NVLink / NVSwitch / fabric)"
  run "topo matrix"       sh -c "nvidia-smi topo -m 2>&1 || echo 'topo unavailable'"
  run "nvlink status"     sh -c "nvidia-smi nvlink --status 2>&1 | head -60 || echo 'no nvlink'"
  run "nvswitch"          sh -c "lspci 2>/dev/null | grep -i 'nvswitch' || echo 'no NVSwitch on PCI'"
  run "fabricmanager"     sh -c "systemctl is-active nvidia-fabricmanager 2>/dev/null || echo 'fabricmanager: not present/inactive'"
  run "nvidia-persist"    sh -c "systemctl is-active nvidia-persistenced 2>/dev/null || echo 'persistenced: not present/inactive'"

  section "F. InfiniBand / RDMA (multi-node fabric, if any)"
  run "ibstat"            sh -c "ibstat 2>&1 | head -40 || echo 'no InfiniBand tooling'"
  run "ib devices"        sh -c "ibv_devices 2>&1 || echo 'no ibverbs'"
  run "rdma links"        sh -c "rdma link show 2>&1 || echo 'no rdma tooling'"
  run "net ifaces"        sh -c "ip -brief addr 2>/dev/null || ip addr"

  section "G. Storage"
  run "df"            df -hT
  run "lsblk"         lsblk
  run "nvme"          sh -c "nvme list 2>/dev/null || echo 'no nvme-cli'"

  section "H. Container runtime"
  run "docker ver"        docker --version
  run "docker info"       sh -c "docker info 2>&1 | grep -Ei 'server version|runtime|cgroup|root dir|storage driver' || echo 'docker info failed (perm? daemon?)'"
  run "nvidia-ctk"        nvidia-ctk --version
  run "daemon.json"       sh -c "cat /etc/docker/daemon.json 2>/dev/null || echo 'no daemon.json'"
  run "nvidia runtime"    sh -c "docker info 2>/dev/null | grep -i nvidia || echo 'nvidia runtime not shown'"
  run "enroot/pyxis"      sh -c "enroot version 2>/dev/null || echo 'no enroot (Slurm/pyxis path)'"
  run "user groups"       id -nG

  section "I. Scheduler / multi-node orchestration (if any)"
  run "slurm"             sh -c "sinfo --version 2>/dev/null && sinfo 2>/dev/null || echo 'no Slurm'"
  run "kubernetes"        sh -c "kubectl version --client 2>/dev/null || echo 'no kubectl'"

  section "J. Python & build tooling"
  run "python3"       python3 --version
  run "python3 path"  which python3
  run "pip"           sh -c "python3 -m pip --version 2>&1 || echo 'no pip'"
  run "venv module"   sh -c "python3 -m venv --help >/dev/null 2>&1 && echo 'venv: ok' || echo 'no venv module'"
  run "uv"            sh -c "uv --version 2>/dev/null || echo 'no uv'"
  run "conda"         conda --version
  run "gcc"           sh -c "gcc --version 2>&1 | head -1 || echo 'no gcc'"
  run "git"           git --version

  section "K. Existing AI stack (avoid reinstalling)"
  run "ollama"        ollama --version
  run "docker images" sh -c "docker images 2>/dev/null | grep -Ei 'nvcr.io|cuda|nemo|triton|tensorrt|ollama|jupyter|vllm|sglang|pytorch' || echo 'none / no docker access'"
  run "running ctr"   sh -c "docker ps 2>/dev/null || echo 'no docker access'"
  run "listeners"     sh -c "ss -tlnp 2>/dev/null | grep -E ':(8888|11434|8000|8080|3000|30000)' || echo 'no relevant listeners'"

  section "END"
  printf 'Report complete.\n'
}

collect | tee "$REPORT"

printf '\n>>> Saved to: %s\n' "$REPORT"
printf '>>> Paste the report above (or the file contents) back to the assistant.\n'
