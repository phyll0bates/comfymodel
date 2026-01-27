#!/bin/bash
set -euo pipefail
mkdir -p /workspace/runpod-slim

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"

# ------------------------------- Functions ---------------------------------- #

setup_ssh() {
    mkdir -p ~/.ssh

    # Generate host keys if they don't exist
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
            ssh-keygen -t ${type} -f "/etc/ssh/ssh_host_${type}_key" -q -N ''
            echo "${type^^} key fingerprint:"
            ssh-keygen -lf "/etc/ssh/ssh_host_${type}_key.pub"
        fi
    done

    # If PUBLIC_KEY is provided, use it
    if [[ "${PUBLIC_KEY:-}" ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Avoid duplicating config lines on every boot
    grep -q '^PermitUserEnvironment yes' /etc/ssh/sshd_config || echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    /usr/sbin/sshd
}

export_env_vars() {
    echo "Exporting environment variables..."

    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_FILE="/root/.ssh/environment"

    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_FILE"
    > /etc/rp_environment

    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH' | while read -r line; do
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)

        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_FILE"
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done

    # Avoid duplicating lines on every boot
    grep -q 'source /etc/rp_environment' ~/.bashrc || echo 'source /etc/rp_environment' >> ~/.bashrc
    grep -q 'source /etc/rp_environment' /etc/bash.bashrc || echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_FILE"
}

start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

ensure_git() {
    if ! command -v git >/dev/null 2>&1; then
        apt-get update && apt-get install -y git ca-certificates >/dev/null
    fi
}

init_filebrowser() {
    # NOTE: hardcoded creds are a bad idea. Prefer env vars.
    FB_USER="${FILEBROWSER_USER:-admin}"
    FB_PASS="${FILEBROWSER_PASS:-adminadmin12}"

    if [ ! -f "$DB_FILE" ]; then
        echo "Initializing FileBrowser..."
        filebrowser config init
        filebrowser config set --address 0.0.0.0
        filebrowser config set --port 8080
        filebrowser config set --root /workspace
        filebrowser config set --auth.method=json
        filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin
    else
        echo "Using existing FileBrowser configuration..."
    fi

    echo "Starting FileBrowser on port 8080..."
    nohup filebrowser &> /filebrowser.log &
}

install_custom_nodes_deps_with_pip() {
    echo "Checking for custom node dependencies (pip)..."
    cd "$COMFYUI_DIR/custom_nodes"
    for node_dir in */; do
        if [ -d "$node_dir" ]; then
            echo "Checking dependencies for $node_dir..."
            cd "$COMFYUI_DIR/custom_nodes/$node_dir"

            if [ -f "requirements.txt" ]; then
                echo "Installing requirements.txt for $node_dir"
                pip install --no-cache-dir -r requirements.txt
            fi

            if [ -f "install.py" ]; then
                echo "Running install.py for $node_dir"
                python install.py
            fi

            if [ -f "setup.py" ]; then
                echo "Running setup.py for $node_dir"
                pip install --no-cache-dir -e .
            fi
        fi
    done
}

bootstrap_template_and_models() {
    TEMPLATE_DIR="/workspace/template"
    TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/TUUSER/TU-REPO.git}"
    TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-main}"

    echo "Bootstrapping template + models..."
    ensure_git

    if [ ! -d "$TEMPLATE_DIR/.git" ]; then
        echo "Clonando template: $TEMPLATE_REPO ($TEMPLATE_BRANCH)"
        rm -rf "$TEMPLATE_DIR"
        git clone --depth 1 --branch "$TEMPLATE_BRANCH" "$TEMPLATE_REPO" "$TEMPLATE_DIR"
    else
        echo "Actualizando template..."
        cd "$TEMPLATE_DIR"
        git fetch --depth 1 origin "$TEMPLATE_BRANCH"
        git reset --hard "origin/$TEMPLATE_BRANCH"
    fi

    # Run fetch_models.sh from template root
    chmod +x "$TEMPLATE_DIR/fetch_models.sh"
    COMFYUI_DIR="$COMFYUI_DIR" MANIFEST="$TEMPLATE_DIR/models_manifest.txt" \
      "$TEMPLATE_DIR/fetch_models.sh"
}

start_comfyui() {
    cd "$COMFYUI_DIR"
    FIXED_ARGS="--listen 0.0.0.0 --port 8188"

    if [ -s "$ARGS_FILE" ]; then
        CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ' || true)
        if [ -n "${CUSTOM_ARGS:-}" ]; then
            echo "Starting ComfyUI with additional arguments: $CUSTOM_ARGS"
            nohup python main.py $FIXED_ARGS $CUSTOM_ARGS &> /workspace/runpod-slim/comfyui.log &
        else
            echo "Starting ComfyUI with default arguments"
            nohup python main.py $FIXED_ARGS &> /workspace/runpod-slim/comfyui.log &
        fi
    else
        echo "Starting ComfyUI with default arguments"
        nohup python main.py $FIXED_ARGS &> /workspace/runpod-slim/comfyui.log &
    fi

    tail -f /workspace/runpod-slim/comfyui.log
}

# ------------------------------- Main --------------------------------------- #

setup_ssh
export_env_vars

init_filebrowser
start_jupyter

# Create default comfyui_args.txt if it doesn't exist
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Installing ComfyUI and dependencies..."
    ensure_git

    if [ ! -d "$COMFYUI_DIR" ]; then
        cd /workspace/runpod-slim
        git clone https://github.com/comfyanonymous/ComfyUI.git
    fi

    if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
        echo "Installing ComfyUI-Manager..."
        mkdir -p "$COMFYUI_DIR/custom_nodes"
        cd "$COMFYUI_DIR/custom_nodes"
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    fi

    CUSTOM_NODES=(
        "https://github.com/kijai/ComfyUI-KJNodes"
        "https://github.com/MoonGoblinDev/Civicomfy"
        "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
    )

    for repo in "${CUSTOM_NODES[@]}"; do
        repo_name=$(basename "$repo")
        if [ ! -d "$COMFYUI_DIR/custom_nodes/$repo_name" ]; then
            echo "Installing $repo_name..."
            cd "$COMFYUI_DIR/custom_nodes"
            git clone "$repo"
        fi
    done

    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        python -m ensurepip --upgrade
        python -m pip install --upgrade pip

        install_custom_nodes_deps_with_pip
    fi
else
    source "$VENV_DIR/bin/activate"
    install_custom_nodes_deps_with_pip
fi

# IMPORTANT: at this point COMFYUI_DIR exists and venv is active -> now fetch models
bootstrap_template_and_models

start_comfyui
