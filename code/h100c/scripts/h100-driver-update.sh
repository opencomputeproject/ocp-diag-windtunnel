#!/usr/bin/env bash
# h100-driver-update.sh — bump the host NVIDIA driver so modern NGC images run.
#
# Why: NGC vllm:26.08 (CUDA 13.x) needs driver >= 615.65; this box has 575.57.08
# (CUDA 12.9), and NGC forward-compat refused to engage (CUDA_ERROR_SYSTEM_
# DRIVER_MISMATCH). We move the host to a current *open* datacenter driver.
#
# H100 is a datacenter GPU -> use NVIDIA's OPEN kernel modules (nvidia-open).
# No NVSwitch on this node (NVLink is 2+2 pairs), so NO fabricmanager needed.
#
# Staged on purpose — run these in order, reboot where told:
#   preflight          Show current driver/kernel/Secure-Boot + install method,
#                      and STOP running GPU containers. Changes nothing else.
#   repo               Add NVIDIA's CUDA apt repo (cuda-keyring) + apt update.
#   list               Show the driver versions the repo offers.
#   install [branch]   Install nvidia-open (latest) or nvidia-open-<branch>.
#   --> then: sudo reboot
#   verify             After reboot: print the new driver via nvidia-smi.
#
# Usage:  bash h100-driver-update.sh <stage> [branch]
#
# NOTE: uses sudo for the apt/driver steps. It will prompt for your password in
#       the terminal — never paste your password to the assistant.

set -u

KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"

say() { printf '\n== %s ==\n' "$*"; }

preflight() {
  say "Current driver / CUDA"
  nvidia-smi --query-gpu=driver_version,name --format=csv 2>/dev/null || echo "(nvidia-smi failed)"
  say "Kernel"
  uname -r
  say "Secure Boot state"
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null || echo "(unknown)"
    echo "If 'SecureBoot enabled': expect a blue MOK-enrollment screen on the"
    echo "NEXT reboot. Choose 'Enroll MOK' and enter the password you set, or the"
    echo "new kernel module won't load."
  else
    echo "mokutil not installed; cannot read Secure Boot. (sudo apt-get install -y mokutil)"
  fi
  say "Driver install method"
  if dpkg -l 2>/dev/null | grep -qE '^ii\s+nvidia-(driver|open|dkms)'; then
    echo "apt-managed driver detected -> apt upgrade path is safe."
  fi
  if [ -x /usr/bin/nvidia-uninstall ]; then
    echo "WARNING: /usr/bin/nvidia-uninstall exists -> 575 was likely installed via"
    echo "the .run file. Run 'sudo /usr/bin/nvidia-uninstall' FIRST, else apt will"
    echo "conflict. Re-run preflight after."
  fi
  say "Container Toolkit (must survive the update)"
  dpkg -l 2>/dev/null | grep -E 'nvidia-container-toolkit|libnvidia-container' || echo "(not dpkg-managed?)"
  say "Stopping running GPU containers (so the driver can be swapped)"
  local running; running="$(docker ps -q 2>/dev/null)"
  if [ -n "$running" ]; then
    docker ps --format '  stopping {{.Names}}' 
    docker stop $running >/dev/null 2>&1 && echo "  done."
  else
    echo "  none running."
  fi
  say "Preflight complete"
  echo "Next: bash h100-driver-update.sh repo"
}

repo() {
  say "Adding NVIDIA CUDA apt repo for ubuntu2404 / x86_64"
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && wget -q "$KEYRING_URL" -O cuda-keyring.deb && sudo dpkg -i cuda-keyring.deb )
  rm -rf "$tmp"
  sudo apt-get update
  say "Repo added. Next: bash h100-driver-update.sh list"
}

list_drivers() {
  say "Open-driver packages available from the repo"
  apt-cache search '^nvidia-open' 2>/dev/null || true
  echo
  say "Versions for 'nvidia-open' (top = newest)"
  apt-cache madison nvidia-open 2>/dev/null | head -10 || echo "(none — did 'repo' run?)"
  echo
  echo "Pick the newest (>= 615.65 to run vllm:26.08). Then:"
  echo "  bash h100-driver-update.sh install            # latest nvidia-open"
  echo "  bash h100-driver-update.sh install 615        # pin nvidia-open-615"
}

install_driver() {
  local branch="${1:-}"
  local pkg="nvidia-open"
  [ -n "$branch" ] && pkg="nvidia-open-${branch}"

  if [ -x /usr/bin/nvidia-uninstall ]; then
    echo "ABORT: runfile driver present. Run 'sudo /usr/bin/nvidia-uninstall' first." >&2
    exit 1
  fi

  # The installed 575-branch userspace libs (libnvidia-compute-575, etc.) Conflict
  # with the new driver's generic packages, and apt won't auto-remove them across
  # a branch jump. Purge the old DRIVER packages first — but NEVER the container
  # toolkit (libnvidia-container*, nvidia-container-*), or Docker GPU access breaks.
  say "Removing old NVIDIA driver packages (keeping the container toolkit)"
  local old
  old="$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -E '^(nvidia-|libnvidia-)' \
        | grep -vE 'container' || true)"
  if [ -n "$old" ]; then
    echo "$old" | sed 's/^/  purge /'
    sudo apt-get --purge remove -y $old || true
  else
    echo "  (none found)"
  fi

  say "Installing $pkg (open kernel modules)"
  # DKMS builds the module against the RUNNING kernel — make sure its headers
  # are present, or the build silently has nothing to compile against.
  sudo apt-get install -y "linux-headers-$(uname -r)" || true
  if sudo apt-get install -y "$pkg"; then
    sudo apt-get autoremove -y
    say "Install OK. A REBOOT is required to load the new kernel module."
    echo "Verify the toolkit survived: dpkg -l | grep nvidia-container-toolkit"
    echo "Run:  sudo reboot"
    echo "After it comes back:  bash h100-driver-update.sh verify"
  else
    say "INSTALL FAILED — do NOT reboot"
    echo "Try:  sudo apt-get install -f   then re-run this stage."
    echo "Paste the output back if it still fails."
    exit 1
  fi
}

verify() {
  say "New driver"
  nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv 2>/dev/null || {
    echo "nvidia-smi failed. If Secure Boot: module may be unsigned/unenrolled."
    echo "Check: mokutil --sb-state ; dmesg | grep -i nvidia"
    return 1
  }
  echo
  echo "If driver_version >= 615.65, vllm:26.08 will run. Bring the plane up:"
  echo "  export HF_TOKEN=hf_xxx"
  echo "  bash h100-serve.sh vllm-up qwen"
  echo "  bash h100-serve.sh vllm-logs"
}

case "${1:-}" in
  preflight) preflight ;;
  repo)      repo ;;
  list)      list_drivers ;;
  install)   install_driver "${2:-}" ;;
  verify)    verify ;;
  *) sed -n '2,28p' "$0"; exit 1 ;;
esac
