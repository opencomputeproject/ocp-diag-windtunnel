#!/usr/bin/env bash
# spark-power.sh — clean power-down / status helper for the DGX Spark.
# Stops all spark-* containers gracefully, then optionally powers off the host.
# Bringing services back UP is deliberately manual (you choose the model):
#   bash spark-serve.sh vllm-up   (or: swap qwen | swap gemma)
#   bash spark-ctl.sh   jupyter-up
#
# Commands:
#   status   Show any running spark-* containers.
#   stop     Gracefully stop & remove all spark-* containers (stay powered on).
#   off      stop, then power off the host (sudo poweroff).
#
# Usage:  bash spark-power.sh <command>

set -u

require_docker() {
  docker info >/dev/null 2>&1 && return 0
  echo "ERROR: cannot reach the Docker daemon (permission denied)." >&2
  echo "Run 'newgrp docker' or log out/in, then retry (see recipe 02)." >&2
  exit 1
}

spark_containers() { docker ps -a --filter 'name=spark-' --format '{{.Names}}'; }

status() {
  echo "Running spark-* containers:"
  docker ps --filter 'name=spark-' \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

stop_all() {
  local names; names="$(spark_containers)"
  if [ -z "$names" ]; then echo "No spark-* containers present."; return 0; fi
  echo "Stopping spark-* containers gracefully (SIGTERM, up to 20s each) ..."
  # shellcheck disable=SC2086
  docker stop -t 20 $names >/dev/null 2>&1
  # shellcheck disable=SC2086
  docker rm $names >/dev/null 2>&1
  echo "Stopped & removed:"; echo "$names" | sed 's/^/  - /'
}

case "${1:-}" in
  status) require_docker; status ;;
  stop)   require_docker; stop_all ;;
  off)    require_docker; stop_all; echo "Powering off ..."; sudo poweroff ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
