#!/usr/bin/env bash
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
MODELS_DIR="$COMFYUI_DIR/models"
MANIFEST="${MANIFEST:-/workspace/template/models_manifest.txt}"

# Validaciones mínimas
if [[ ! -d "$COMFYUI_DIR" ]]; then
  echo "[err] COMFYUI_DIR no existe: $COMFYUI_DIR" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "[err] Manifest no existe: $MANIFEST" >&2
  exit 1
fi

# Herramientas
if ! command -v aria2c >/dev/null 2>&1; then
  apt-get update && apt-get install -y aria2 ca-certificates >/dev/null
fi

mkdir -p "$MODELS_DIR"

echo "[i] Leyendo manifest: $MANIFEST"

# Lee línea por línea preservando espacios
while IFS= read -r line || [[ -n "$line" ]]; do
  # trim básico
  line="${line#"${line%%[![:space:]]*}"}"  # ltrim
  [[ -z "$line" ]] && continue
  [[ "${line:0:1}" == "#" ]] && continue

  # Partir en 2 campos: URL y ruta (separadas por espacio)
  url="${line%%[[:space:]]*}"
  relpath="${line#"$url"}"
  relpath="${relpath#"${relpath%%[![:space:]]*}"}"  # ltrim relpath

  if [[ -z "$url" || -z "$relpath" || "$url" == "$relpath" ]]; then
    echo "[err] Línea inválida (usa: URL<espacio>ruta): $line" >&2
    exit 1
  fi

  dest="$MODELS_DIR/$relpath"
  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    echo "[skip] $relpath"
    continue
  fi

  echo "[dl] $relpath"
  aria2c -x 8 -s 8 -k 1M --continue=true --allow-overwrite=true \
    --check-certificate=true \
    -o "$(basename "$dest")" -d "$(dirname "$dest")" "$url"
done < "$MANIFEST"
