#!/usr/bin/env bash
# ComfyUI Universal Installer V2.1.1-dev1
# Linux x86_64 / AMD64
# NVIDIA GPU / CPU
# Debian / Ubuntu / RHEL family

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.1.1-dev1"
IMAGE="yanwk/comfyui-boot"
CONTAINER="comfyui"
DEFAULT_DATA="/opt/comfyui-data"
DEFAULT_DOCKER="/opt/docker-data"
DEFAULT_CONTAINERD="/opt/containerd-data"
DEFAULT_PORT=8188

LOG="/var/log/comfyui-installer.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

LANG_CODE="en"
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}" in
    zh*) LANG_CODE="zh" ;;
esac

msg() {
    if [[ "$LANG_CODE" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

info() {
    echo -e "${GREEN}[INFO]${RESET} $*"
    echo "[INFO] $*" >> "$LOG"
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
    echo "[WARN] $*" >> "$LOG"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*"
    echo "[ERROR] $*" >> "$LOG"
    exit 1
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    while true; do
        if [[ "$default" == "y" ]]; then
            read -r -p "$prompt [Y/n] " answer
            answer="${answer:-y}"
        else
            read -r -p "$prompt [y/N] " answer
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

ask_number() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local default="$4"
    local answer

    while true; do
        read -r -p "$prompt [$min-$max, default $default]: " answer
        answer="${answer:-$default}"

        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           (( answer >= min && answer <= max )); then
            echo "$answer"
            return
        fi

        echo "Invalid selection."
    done
}

require_root() {
    [[ "$EUID" -eq 0 ]] ||
        error "$(msg '请使用 root 或 sudo 运行。' 'Run as root or with sudo.')"
}

check_platform() {
    [[ "$(uname -m)" == "x86_64" ]] ||
        error "$(msg '仅支持 Linux x86_64，不支持 ARM64。' 'Only Linux x86_64 is supported. ARM64 is not supported.')"

    [[ -r /etc/os-release ]] ||
        error "$(msg '无法识别系统。' 'Cannot identify operating system.')"

    source /etc/os-release

    case "$ID" in
        debian|ubuntu|linuxmint|pop)
            OS_FAMILY="debian"
            ;;
        rhel|rocky|almalinux|centos|fedora)
            OS_FAMILY="rhel"
            ;;
        *)
            error "Unsupported distribution: $PRETTY_NAME"
            ;;
    esac

    info "System: ${PRETTY_NAME:-Linux}"
}

check_commands() {
    local cmd
    for cmd in curl df findmnt lsblk awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 ||
            error "Missing command: $cmd"
    done
}

show_disks() {
    echo
    echo "========== DISK INFORMATION =========="
    lsblk -e 7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS || true
    echo
    df -hT -x tmpfs -x devtmpfs || df -h
    echo
}

validate_path() {
    local path="$1"

    [[ "$path" == /* ]] ||
        error "Path must be absolute."

    [[ "$path" != "/" ]] ||
        error "Cannot use root directory."

    case "$path" in
        /root|/home|/etc|/usr|/var|/boot|/proc|/sys|/dev|/run|/opt)
            error "Cannot directly use a system directory: $path"
            ;;
    esac

    [[ "$path" != *"/../"* && "$path" != */.. ]] ||
        error "Path must not contain .."
}

choose_path() {
    local title="$1"
    local default="$2"
    local path

    echo
    echo "$title"
    read -r -p "Path [$default]: " path

    path="${path:-$default}"
    validate_path "$path"

    echo "$path"
}

inspect_path() {
    local path="$1"

    mkdir -p "$path"

    echo "Path: $path"
    echo "Mount: $(findmnt -n -o TARGET -T "$path" || true)"
    echo "Filesystem: $(findmnt -n -o FSTYPE -T "$path" || true)"
    echo "Available space:"
    df -h "$path"
}

detect_gpu() {
    GPU_MODE="cpu"
    GPU_TAG="cpu"

    if command -v nvidia-smi >/dev/null 2>&1 &&
       nvidia-smi -L >/dev/null 2>&1; then

        GPU_MODE="nvidia"

        local -a GPUs
        mapfile -t GPUs < <(
            nvidia-smi --query-gpu=name --format=csv,noheader
        )

        echo
        echo "Detected NVIDIA GPUs:"
        printf ' - %s\n' "${GPUs[@]}"

        local blackwell=0
        local hopper=0
        local legacy=0
        local unknown=0

        local gpu
        for gpu in "${GPUs[@]}"; do
            local name="${gpu^^}"

            case "$name" in
                *RTX*50*|*BLACKWELL*|*B100*|*B200*)
                    blackwell=1
                    ;;
                *H100*|*H200*|*GH200*)
                    hopper=1
                    ;;
                *V100*|*P102*|*P104*|*P106*|*P100*|*P40*|*P10*|*P4*|*GTX\ 10*|*GTX\ 9*|*QUADRO\ P*)
                    legacy=1
                    ;;
                *RTX*40*|*RTX*30*|*RTX*20*|*GTX\ 16*|*A100*|*A10*|*A30*|*A40*|*L4*|*L40*|*T4*|*T1000*|*T2000*)
                    ;;
                *)
                    unknown=1
                    ;;
            esac
        done

        if (( unknown )); then
            echo "Unknown NVIDIA GPU architecture."
            echo "1) cu130-slim-v2"
            echo "2) cu126-slim"

            local choice
            choice="$(ask_number "Select image" 1 2 1)"

            if [[ "$choice" == "1" ]]; then
                GPU_TAG="cu130-slim-v2"
            else
                GPU_TAG="cu126-slim"
            fi

        elif (( blackwell || hopper )); then
            (( legacy == 0 )) ||
                error "Mixed GPU architectures are not supported by one image."

            GPU_TAG="cu130-slim-v2"

        elif (( legacy )); then
            GPU_TAG="cu126-slim"

        else
            GPU_TAG="cu130-slim-v2"
        fi

    else
        warn "NVIDIA GPU not available. CPU mode selected."
    fi

    info "Selected image: ${IMAGE}:${GPU_TAG}"
}

install_docker_if_missing() {
    if command -v docker >/dev/null 2>&1; then
        DOCKER_EXISTING=1
        info "Existing Docker detected. Existing storage will be preserved."
        return
    fi

    DOCKER_EXISTING=0

    warn "Docker is not installed."

    ask_yes_no "Install Docker from Docker official installer?" y ||
        error "Docker installation cancelled."

    curl -fL --retry 2 \
        https://get.docker.com \
        -o /tmp/comfyui-get-docker.sh

    bash /tmp/comfyui-get-docker.sh
    rm -f /tmp/comfyui-get-docker.sh

    systemctl stop docker.service docker.socket containerd.service \
        2>/dev/null || true
}

configure_new_docker_storage() {
    [[ "$DOCKER_EXISTING" == "0" ]] || return 0

    mkdir -p "$DOCKER_ROOT" "$CONTAINERD_ROOT"
    chmod 0711 "$DOCKER_ROOT" "$CONTAINERD_ROOT"

    python3 - "$DOCKER_ROOT" <<'PY'
import json
import os
import sys

path = "/etc/docker/daemon.json"
root = sys.argv[1]

data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

data["data-root"] = root

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

os.replace(tmp, path)
PY

    if command -v containerd >/dev/null 2>&1; then
        if [[ ! -s /etc/containerd/config.toml ]]; then
            containerd config default > /etc/containerd/config.toml
        fi

        if grep -qE '^[[:space:]]*root[[:space:]]*=' \
            /etc/containerd/config.toml; then

            sed -i -E \
                "s|^[[:space:]]*root[[:space:]]*=.*|root = \"$CONTAINERD_ROOT\"|" \
                /etc/containerd/config.toml
        else
            error "Cannot safely locate containerd root setting."
        fi
    else
        error "containerd is missing."
    fi

    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl enable --now docker
}

check_docker() {
    command -v docker >/dev/null 2>&1 ||
        error "Docker is not installed."

    systemctl is-active --quiet docker ||
        systemctl start docker

    docker info >/dev/null 2>&1 ||
        error "Docker daemon unavailable."
}

show_registry_mirrors() {
    local mirrors
    mirrors="$(docker info --format '{{json .RegistryConfig.Mirrors}}' 2>/dev/null || echo '[]')"

    info "Configured Docker registry mirrors: $mirrors"

    if [[ "$mirrors" == "[]" || "$mirrors" == "null" ]]; then
        warn "No Docker registry mirror configured. Using Docker Hub."
    fi
}

pull_image() {
    local image="$1"
    local attempt

    for attempt in 1 2 3; do
        info "Pulling $image (attempt $attempt/3)"

        if docker pull "$image"; then
            return 0
        fi

        sleep $((attempt * 5))
    done

    return 1
}

choose_access() {
    echo
    echo "1) Local only (127.0.0.1)"
    echo "2) LAN access (0.0.0.0)"

    local choice
    choice="$(ask_number "Access mode" 1 2 1)"

    if [[ "$choice" == "1" ]]; then
        BIND="127.0.0.1"
    else
        BIND="0.0.0.0"
        warn "LAN mode listens on all IPv4 interfaces. Do not expose directly to the Internet."
    fi
}

choose_port() {
    local port
    read -r -p "Port [default $DEFAULT_PORT]: " port

    PORT="${port:-$DEFAULT_PORT}"

    [[ "$PORT" =~ ^[0-9]+$ ]] &&
        (( PORT >= 1 && PORT <= 65535 )) ||
        error "Invalid port."

    if command -v ss >/dev/null 2>&1 &&
       ss -H -ltn | awk '{print $4}' | grep -Eq "(:|\.)${PORT}$"; then
        error "Port $PORT is already occupied."
    fi
}

prepare_data() {
    mkdir -p \
        "$DATA_ROOT/cache/dot-cache" \
        "$DATA_ROOT/cache/dot-config" \
        "$DATA_ROOT/nodes/dot-local" \
        "$DATA_ROOT/nodes/custom_nodes" \
        "$DATA_ROOT/models/models" \
        "$DATA_ROOT/models/hf-hub" \
        "$DATA_ROOT/models/torch-hub" \
        "$DATA_ROOT/user/input" \
        "$DATA_ROOT/user/output" \
        "$DATA_ROOT/user/user-profile" \
        "$DATA_ROOT/user/user-scripts"
}

replace_old_container() {
    OLD_CONTAINER=""

    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        warn "Existing ComfyUI container found."

        ask_yes_no "Stop and preserve the old container before replacement?" n ||
            error "Deployment cancelled."

        OLD_CONTAINER="${CONTAINER}-backup-$(date +%Y%m%d-%H%M%S)"

        docker inspect "$CONTAINER" \
            > "$DATA_ROOT/old-container-inspect.json"

        docker stop "$CONTAINER" >/dev/null || true
        docker rename "$CONTAINER" "$OLD_CONTAINER"

        info "Old container preserved as $OLD_CONTAINER"
    fi
}

run_container() {
    local -a GPU_ARGS=()

    [[ "$GPU_MODE" == "nvidia" ]] &&
        GPU_ARGS=(--gpus all)

    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        "${GPU_ARGS[@]}" \
        -p "${BIND}:${PORT}:8188" \
        -v "$DATA_ROOT/cache/dot-cache:/root/.cache" \
        -v "$DATA_ROOT/cache/dot-config:/root/.config" \
        -v "$DATA_ROOT/nodes/dot-local:/root/.local" \
        -v "$DATA_ROOT/nodes/custom_nodes:/root/ComfyUI/custom_nodes" \
        -v "$DATA_ROOT/models/models:/root/ComfyUI/models" \
        -v "$DATA_ROOT/models/hf-hub:/root/.cache/huggingface/hub" \
        -v "$DATA_ROOT/models/torch-hub:/root/.cache/torch/hub" \
        -v "$DATA_ROOT/user/input:/root/ComfyUI/input" \
        -v "$DATA_ROOT/user/output:/root/ComfyUI/output" \
        -v "$DATA_ROOT/user/user-profile:/root/ComfyUI/user" \
        -v "$DATA_ROOT/user/user-scripts:/root/user-scripts" \
        "${IMAGE}:${GPU_TAG}"
}

wait_for_health() {
    local i

    for i in $(seq 1 180); do
        if curl -fsS --max-time 3 \
            "http://127.0.0.1:${PORT}/system_stats" \
            >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
    done

    return 1
}

rollback() {
    warn "Attempting rollback."

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

    if [[ -n "$OLD_CONTAINER" ]] &&
       docker container inspect "$OLD_CONTAINER" >/dev/null 2>&1; then

        docker rename "$OLD_CONTAINER" "$CONTAINER"
        docker start "$CONTAINER" >/dev/null || true
    fi
}

main() {
    require_root
    check_platform
    check_commands

    echo
    echo "ComfyUI Universal Installer v${VERSION}"
    echo "======================================"

    show_disks
    detect_gpu

    DATA_ROOT="$(choose_path \
        "ComfyUI data directory" "$DEFAULT_DATA")"

    if command -v docker >/dev/null 2>&1; then
        DOCKER_EXISTING=1
        DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo unknown)"
        CONTAINERD_ROOT="Existing containerd location (unchanged)"

        warn "Existing Docker storage will not be migrated automatically."
    else
        DOCKER_EXISTING=0

        DOCKER_ROOT="$(choose_path \
            "Docker data directory" "$DEFAULT_DOCKER")"

        CONTAINERD_ROOT="$(choose_path \
            "containerd data directory" "$DEFAULT_CONTAINERD")"
    fi

    echo
    echo "Storage inspection:"
    inspect_path "$DATA_ROOT"

    if [[ "$DOCKER_EXISTING" == "0" ]]; then
        inspect_path "$DOCKER_ROOT"
        inspect_path "$CONTAINERD_ROOT"
    fi

    choose_access
    choose_port

    echo
    echo "========== DEPLOYMENT SUMMARY =========="
    echo "Image: ${IMAGE}:${GPU_TAG}"
    echo "GPU: $GPU_MODE"
    echo "ComfyUI data: $DATA_ROOT"
    echo "Docker data: $DOCKER_ROOT"
    echo "containerd data: $CONTAINERD_ROOT"
    echo "Bind: $BIND"
    echo "Port: $PORT"
    echo "========================================"

    ask_yes_no "Start deployment?" n ||
        exit 0

    install_docker_if_missing
    configure_new_docker_storage
    check_docker
    show_registry_mirrors

    prepare_data

    pull_image "${IMAGE}:${GPU_TAG}" ||
        error "Image pull failed. Existing container was not stopped."

    replace_old_container

    if ! run_container; then
        rollback
        error "Container creation failed."
    fi

    if ! wait_for_health; then
        docker logs --tail 160 "$CONTAINER" || true
        rollback
        error "ComfyUI health check timed out."
    fi

    echo
    echo -e "${GREEN}Deployment successful!${RESET}"

    if [[ "$BIND" == "127.0.0.1" ]]; then
        echo "http://127.0.0.1:${PORT}"
    else
        echo "http://<server-LAN-IP>:${PORT}"
        echo "Listening on 0.0.0.0"
    fi

    echo
    echo "Useful commands:"
    echo "docker logs -f $CONTAINER"
    echo "docker restart $CONTAINER"
    echo "docker stop $CONTAINER"
    echo "docker start $CONTAINER"
    echo
    echo "Data directory: $DATA_ROOT"
    echo "Log: $LOG"
}

main "$@"
