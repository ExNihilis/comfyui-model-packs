#!/bin/bash
# Pack downloader for ComfyUI RunPod template
# Downloads model packs from manifest files

set -e

LOG_FILE="/workspace/pack-download.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date)] Starting pack download..."

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
MODELS_DIR="${MODELS_DIR:-$COMFYUI_DIR/models}"
WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
PACKS_BASE_URL="${PACKS_BASE_URL:-https://raw.githubusercontent.com/ExNihilis/comfyui-model-packs/main}"

# Wait for ComfyUI to be set up
echo "[$(date)] Waiting for ComfyUI installation..."
for i in $(seq 1 120); do
  if [ -d "$COMFYUI_DIR" ] && [ -d "$MODELS_DIR" ]; then
    break
  fi
  sleep 5
done

if [ ! -d "$COMFYUI_DIR" ]; then
  echo "[$(date)] ERROR: ComfyUI directory never appeared at $COMFYUI_DIR"
  exit 1
fi

# Ensure directories exist
mkdir -p "$MODELS_DIR"
mkdir -p "$WORKFLOWS_DIR"
mkdir -p "$CUSTOM_NODES_DIR"

# Get MODEL_PACK env var
if [ -z "${MODEL_PACK:-}" ]; then
  echo "[$(date)] No MODEL_PACK specified, skipping downloads"
  exit 0
fi

# Find python for pip installs
VENV_PYTHON="$COMFYUI_DIR/.venv-cu128/bin/python"
if [ -x "$VENV_PYTHON" ]; then
  PYTHON_BIN="$VENV_PYTHON"
elif [ -x "$COMFYUI_DIR/.venv/bin/python" ]; then
  PYTHON_BIN="$COMFYUI_DIR/.venv/bin/python"
else
  PYTHON_BIN="$(command -v python3 || command -v python)"
fi

if [ -f /opt/comfyui-runtime-constraints.txt ] && [ -z "${PIP_CONSTRAINT:-}" ]; then
  export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt
fi

NODES_CHANGED=0

# Split by comma
IFS=',' read -ra PACKS <<< "$MODEL_PACK"
for pack in "${PACKS[@]}"; do
  # Trim whitespace
  pack=$(echo "$pack" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$pack" ] && continue
  
  echo "[$(date)] Processing pack: $pack"
  # Try new structure first (modelpack.txt in folder), fallback to old structure
  MANIFEST_URL="$PACKS_BASE_URL/${pack}/modelpack.txt"
  TMP_MANIFEST="/tmp/pack_${pack}.txt"
  
  echo "[$(date)] Fetching manifest from $MANIFEST_URL"
  if ! curl -fsSL "$MANIFEST_URL" -o "$TMP_MANIFEST"; then
    echo "[$(date)] Trying legacy manifest location..."
    MANIFEST_URL="$PACKS_BASE_URL/${pack}.txt"
    if ! curl -fsSL "$MANIFEST_URL" -o "$TMP_MANIFEST"; then
      echo "[$(date)] WARNING: Failed to fetch manifest for pack $pack"
      continue
    fi
  fi
  
  # Process manifest
  while IFS='|' read -r subfolder filename url || [ -n "$subfolder" ]; do
    # Skip comments and empty lines
    [[ "$subfolder" =~ ^[[:space:]]*# ]] && continue
    [ -z "$subfolder" ] && continue
    [ -z "$filename" ] && continue
    [ -z "$url" ] && continue
    
    # Trim whitespace
    subfolder=$(echo "$subfolder" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    filename=$(echo "$filename" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    url=$(echo "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
    
    # Handle nodes (git repos)
    if [ "$subfolder" = "nodes" ] || [ "$subfolder" = "node" ] || [ "$subfolder" = "custom_nodes" ]; then
      cd "$CUSTOM_NODES_DIR" || continue
      node_name=$(basename "$url" .git)
      node_name=$(echo "$node_name" | sed 's/\.git$//')
      # If filename is specified and different, maybe use it as node name? Or use from URL
      if [ -n "$filename" ] && [ "$filename" != "-" ] && [ "$filename" != "$node_name" ]; then
        # Try to use filename as hint, but better to derive from URL
        :
      fi
      node_name=$(basename "$url" .git)
      if [ -d "$CUSTOM_NODES_DIR/$node_name" ]; then
        echo "[$(date)] UPDATE $node_name (git pull)"
        old_head=$(git -C "$node_name" rev-parse HEAD 2>/dev/null || echo "")
        if git -C "$node_name" pull --ff-only >/dev/null 2>&1; then
          new_head=$(git -C "$node_name" rev-parse HEAD 2>/dev/null || echo "")
          if [ "$old_head" != "$new_head" ]; then
            NODES_CHANGED=1
          fi
        else
          echo "[$(date)] WARNING: Failed to update $node_name"
        fi
      else
        echo "[$(date)] CLONE $node_name from $url"
        if git clone "$url" "$node_name" >/dev/null 2>&1; then
          NODES_CHANGED=1
        else
          echo "[$(date)] FAIL   $node_name"
          continue
        fi
      fi
      # Install requirements if they exist
      if [ -f "$CUSTOM_NODES_DIR/$node_name/requirements.txt" ]; then
        echo "[$(date)] PIP    Installing requirements for $node_name"
        "$PYTHON_BIN" -m pip install --disable-pip-version-check --no-input -q -r "$CUSTOM_NODES_DIR/$node_name/requirements.txt" >/dev/null 2>&1 || echo "[$(date)] WARNING: pip install failed for $node_name requirements"
      fi
      continue
    fi
    
    # Handle workflows
    if [ "$subfolder" = "workflows" ] || [ "$subfolder" = "workflow" ]; then
      dest="$WORKFLOWS_DIR/$filename"
      mkdir -p "$WORKFLOWS_DIR"
    else
      dest="$MODELS_DIR/$subfolder/$filename"
      mkdir -p "$MODELS_DIR/$subfolder"
    fi
    
    # Check if file already exists and is non-empty
    if [ -s "$dest" ]; then
      echo "[$(date)] SKIP  $subfolder/$filename (already present)"
      continue
    fi
    
    echo "[$(date)] GET   $subfolder/$filename"
    
    # Handle authentication for HuggingFace and CivitAI
    auth=()
    if [[ "$url" == https://huggingface.co/* ]]; then
      if [ -n "${HF_TOKEN:-}" ]; then
        auth=(-H "Authorization: Bearer $HF_TOKEN")
      else
        echo "[$(date)] WARNING: HuggingFace URL detected but HF_TOKEN not set (may fail for gated models)"
      fi
    elif [[ "$url" == *civitai.com/* ]]; then
      if [ -n "${CIVITAI_TOKEN:-}" ]; then
        auth=(-H "Authorization: Bearer $CIVITAI_TOKEN")
      else
        echo "[$(date)] WARNING: CivitAI URL detected but CIVITAI_TOKEN not set (may fail for gated/restricted models)"
      fi
    fi
    
    # Download with resume support
    if curl -fL --retry 3 --retry-delay 2 -C - -sS "${auth[@]}" -o "$dest.partial" "$url"; then
      mv "$dest.partial" "$dest"
      echo "[$(date)] DONE  $subfolder/$filename"
    else
      echo "[$(date)] FAIL  $subfolder/$filename"
      rm -f "$dest.partial"
    fi
  done < "$TMP_MANIFEST"
  
  rm -f "$TMP_MANIFEST"
done

# If nodes were changed, try to restart ComfyUI if it's running
if [ "$NODES_CHANGED" = "1" ]; then
  echo "[$(date)] Custom nodes changed. Attempting to reload via ComfyUI Manager if available..."
  # Try ComfyUI Manager reboot endpoint first (safer)
  if curl -s --connect-timeout 3 -X POST "http://127.0.0.1:8188/manager/reboot" >/dev/null 2>&1; then
    echo "[$(date)] Requested ComfyUI restart via Manager API"
    sleep 15
  else
    echo "[$(date)] Manager API not available. Custom nodes installed - ComfyUI may need a restart to load them."
    echo "[$(date)] You can restart the pod or refresh after ComfyUI is back up."
  fi
fi

echo "[$(date)] Pack download complete"
