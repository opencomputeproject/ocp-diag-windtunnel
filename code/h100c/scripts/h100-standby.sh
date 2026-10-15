#!/usr/bin/env bash
# h100-standby.sh — reversibly free the box for OUR stack WITHOUT deleting
# anything. It STOPS (does not remove) pre-existing containers so their GPUs
# and ports are freed, and can START them again later. Images, volumes, and
# the containers themselves stay fully intact.
#
# Use this instead of h100-clean.sh when you want to "do our thing" alongside
# the existing stack rather than wipe it.
#
# Commands:
#   stop [names...]   Stop running containers so the box is free for us.
#                     Default target: every running container EXCEPT the ones we
#                     manage (h100-jupyter, h100-vllm). The names we stop are
#                     recorded so 'restore' can bring exactly those back.
#   restore           Start again the containers that THIS script stopped.
#   status            Show all containers (running + stopped) and GPU usage.
#
# SAFE: never runs rm/rmi/prune. Fully reversible. Nothing is deleted.
#
# Usage:  bash h100-standby.sh <command> [args]

set -u

# Containers our own scripts own — never auto-stopped as "foreign".
MANAGED=(h100-jupyter h100-vllm)
STATE="${H100_STANDBY_STATE:-$HOME/.h100c-standby}"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot reach the Docker daemon (permission or daemon down)." >&2
  exit 1
fi

is_managed() { local n="$1" m; for m in "${MANAGED[@]}"; do [ "$m" = "$n" ] && return 0; done; return 1; }

stop_cmd() {
  shift  # drop 'stop'
  local -a targets=()
  if [ "$#" -gt 0 ]; then
    targets=("$@")                       # explicit names from the caller
  else
    # Default: all running containers that we don't manage ourselves.
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      is_managed "$n" && continue
      targets+=("$n")
    done < <(docker ps --format '{{.Names}}')
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "Nothing to stop (no foreign running containers)."
    return 0
  fi

  : > "$STATE"
  echo "Stopping (keeping intact):"
  local n
  for n in "${targets[@]}"; do
    if docker stop "$n" >/dev/null 2>&1; then
      echo "  stopped  $n"
      echo "$n" >> "$STATE"
    else
      echo "  SKIP     $n (not running or not found)"
    fi
  done
  echo "Recorded in: $STATE  (use 'restore' to bring these back)"
}

restore_cmd() {
  if [ ! -s "$STATE" ]; then
    echo "No standby record at $STATE — nothing to restore."
    return 0
  fi
  echo "Restoring containers this script stopped:"
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if docker start "$n" >/dev/null 2>&1; then
      echo "  started  $n"
    else
      echo "  FAIL     $n (removed, or renamed?)"
    fi
  done < "$STATE"
  echo "Leaving record in place: $STATE"
}

status_cmd() {
  echo "All containers (running + stopped):"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  echo
  echo "GPU usage:"
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv 2>/dev/null \
    || echo "  (nvidia-smi unavailable)"
  if [ -s "$STATE" ]; then
    echo
    echo "On standby (stopped by this script): $(tr '\n' ' ' < "$STATE")"
  fi
}

case "${1:-}" in
  stop)    stop_cmd "$@" ;;
  restore) restore_cmd ;;
  status)  status_cmd ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
