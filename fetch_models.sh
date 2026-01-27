#!/usr/bin/env bash
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
MODELS_DIR="$COMFYUI_DIR/models"
MANIFEST="${MANIFEST:-/workspace/template/models_manifest.txt}"

# Prioridad: si existe MODEL_PRIORITY (Edit Pod env var), prioriza esa categoría
PRIORITY_CATEGORY="${MODEL_PRIORITY:-}"

# Validaciones mínimas
if [[ ! -d "$COMFYUI_DIR" ]]; then
  echo "[err] COMFYUI_DIR no existe: $COMFYUI_DIR" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "[err] Manifest no existe: $MANIFEST" >&2
  exit 1
fi

# herramientas
if ! command -v aria2c >/dev/null 2>&1; then
  apt-get update && apt-get install -y aria2 ca-certificates >/dev/null
fi

mkdir -p "$MODELS_DIR"

download_one() {
  local category="$1"
  local url="$2"
  local relpath="$3"

  local dest="$MODELS_DIR/$relpath"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    echo "[skip] [$category] $relpath"
    return 0
  fi

  echo "[dl]   [$category] $relpath"
  aria2c -x 8 -s 8 -k 1M --continue=true --allow-overwrite=true \
    --check-certificate=true \
    -o "$(basename "$dest")" -d "$(dirname "$dest")" "$url"
}

process_manifest() {
  local mode="$1"  # "priority" o "rest"

  while IFS= read -r line || [[ -n "$line" ]]; do
    # ltrim
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    # Parse: CATEGORY URL DEST
    local category url relpath rest
    category="${line%%[[:space:]]*}"
    rest="${line#"$category"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    url="${rest%%[[:space:]]*}"
    relpath="${rest#"$url"}"
    relpath="${relpath#"${relpath%%[![:space:]]*}"}"

    if [[ -z "${category:-}" || -z "${url:-}" || -z "${relpath:-}" || "$url" == "$relpath" ]]; then
      echo "[err] Línea inválida (usa: CATEGORIA URL DESTINO): $line" >&2
      exit 1
    fi

    if [[ "$mode" == "priority" ]]; then
      [[ -z "$PRIORITY_CATEGORY" ]] && continue
      [[ "$category" != "$PRIORITY_CATEGORY" ]] && continue
    else
      [[ -n "$PRIORITY_CATEGORY" && "$category" == "$PRIORITY_CATEGORY" ]] && continue
    fi

    download_one "$category" "$url" "$relpath"
  done < "$MANIFEST"
}

echo "[i] Manifest: $MANIFEST"
if [[ -n "$PRIORITY_CATEGORY" ]]; then
  echo "[i] Prioridad activada: $PRIORITY_CATEGORY (env var MODEL_PRIORITY)"
  process_manifest "priority"
fi
process_manifest "rest"
