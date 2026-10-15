#!/usr/bin/env bash
# h100-clean.sh — wipe the existing ad-hoc AI stack to a clean slate.
#
# What it removes (in order):
#   1. The running Ollama container (h100-ollama) + any other ollama containers.
#   2. Ollama model data volumes attached to those containers (THIS DELETES
#      DOWNLOADED MODELS — intentional for a clean slate).
#   3. The ollama/ollama image, and the stray nvidia/cuda base image found on box.
#   4. Dangling images, stopped containers, unused networks, build cache (prune).
#
# What it NEVER touches:
#   - The OS, NVIDIA driver, CUDA toolkit, Docker engine, or NVIDIA runtime.
#   - Any image/container you pass in --keep.
#
# SAFETY: dry-run by DEFAULT. It only prints what it *would* do until you pass
# --yes. Run it once, read the plan, then re-run with --yes.
#
# Usage:
#   bash h100-clean.sh                 # dry run: show the plan, change nothing
#   bash h100-clean.sh --yes           # actually remove ollama stack + prune
#   bash h100-clean.sh --yes --all-images   # also remove ALL docker images
#   bash h100-clean.sh --keep foo:bar  # protect an image/container from removal
#
# After this, use h100-serve.sh to bring up the fresh vLLM plane on :8000.

set -u

DO_IT=0
ALL_IMAGES=0
KEEP=()

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)       DO_IT=1 ;;
    --all-images)   ALL_IMAGES=1 ;;
    --keep)         shift; [ $# -gt 0 ] && KEEP+=("$1") ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot reach the Docker daemon (permission or daemon down)." >&2
  exit 1
fi

mode() { [ "$DO_IT" = 1 ] && echo "EXECUTE" || echo "DRY-RUN"; }
# Run a mutating command only when --yes is set; otherwise just print it.
act() {
  printf '  %s $ %s\n' "$(mode)" "$*"
  [ "$DO_IT" = 1 ] && "$@" 2>&1 | sed 's/^/    /'
  return 0
}
protected() {
  local item="$1" k
  for k in "${KEEP[@]:-}"; do [ "$k" = "$item" ] && return 0; done
  return 1
}

echo "=============================================================="
echo " h100-clean — mode: $(mode)"
[ "$DO_IT" = 0 ] && echo " (nothing will change; re-run with --yes to apply)"
echo "=============================================================="

# ---- 1. Ollama containers ---------------------------------------------------
echo
echo "## 1. Ollama containers"
# Match by name 'ollama' OR by ancestor image 'ollama/ollama'.
OLLAMA_CTRS="$(
  { docker ps -aq --filter 'name=ollama'
    docker ps -aq --filter 'ancestor=ollama/ollama:latest'; } 2>/dev/null | sort -u
)"
if [ -z "$OLLAMA_CTRS" ]; then
  echo "  none found"
else
  # Capture model volumes BEFORE removing the containers that reference them.
  OLLAMA_VOLS="$(
    for c in $OLLAMA_CTRS; do
      docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$c" 2>/dev/null
    done | sort -u
  )"
  for c in $OLLAMA_CTRS; do
    name="$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null | sed 's#^/##')"
    if protected "$name"; then echo "  keep (protected): $name"; continue; fi
    act docker rm -f "$c"
  done
fi

# ---- 2. Ollama model volumes (deletes downloaded models) --------------------
echo
echo "## 2. Ollama model data volumes (downloaded models will be deleted)"
if [ -z "${OLLAMA_VOLS:-}" ]; then
  echo "  none attached to ollama containers"
else
  for v in $OLLAMA_VOLS; do
    if protected "$v"; then echo "  keep (protected): $v"; continue; fi
    act docker volume rm "$v"
  done
fi

# ---- 3. Images --------------------------------------------------------------
echo
echo "## 3. Images"
if [ "$ALL_IMAGES" = 1 ]; then
  echo "  --all-images set: removing ALL docker images"
  for img in $(docker images -q | sort -u); do
    tags="$(docker inspect -f '{{join .RepoTags ","}}' "$img" 2>/dev/null)"
    if protected "$tags" || protected "$img"; then echo "  keep (protected): $tags"; continue; fi
    act docker rmi -f "$img"
  done
else
  # Targeted removal of the discovered ad-hoc AI images.
  for img in "ollama/ollama:latest" "nvidia/cuda:12.4.0-base-ubuntu22.04"; do
    if protected "$img"; then echo "  keep (protected): $img"; continue; fi
    if docker image inspect "$img" >/dev/null 2>&1; then
      act docker rmi -f "$img"
    else
      echo "  not present: $img"
    fi
  done
fi

# ---- 4. Prune leftovers -----------------------------------------------------
echo
echo "## 4. Prune stopped containers / dangling images / unused nets / build cache"
act docker container prune -f
act docker image prune -f
act docker network prune -f
act docker builder prune -f
echo
echo "  (volumes are NOT blanket-pruned to avoid nuking unrelated data;"
echo "   ollama volumes were handled explicitly in step 2.)"

echo
echo "=============================================================="
if [ "$DO_IT" = 1 ]; then
  echo " DONE. Remaining images / containers:"
  docker images 2>/dev/null | sed 's/^/   /'
  echo "   ---"
  docker ps -a 2>/dev/null | sed 's/^/   /'
  echo
  echo " Clean slate ready. Next: bash h100-serve.sh vllm-up <model>"
else
  echo " DRY-RUN complete. Re-run with --yes to apply:"
  echo "   bash h100-clean.sh --yes"
fi
echo "=============================================================="
