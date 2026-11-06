#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.1.1"
IMAGE="yanwk/comfyui-boot"
CONTAINER="comfyui"
DEFAULT_DATA="/opt/comfyui-data"
DEFAULT_PORT=8188

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

info() { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || error "请使用 sudo bash $0 运行"
[[ "$(uname -m)" == "x86_64" ]] || error "仅支持 x86_64"

if [[ ! -f /etc/os-release ]]; then error "无法识别系统"; fi
source /etc/os-release

info "系统: ${PRETTY_NAME:-Linux}"

if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

GPU_FLAG=""
IMAGE_TAG="cu126-slim"
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)
    info "检测到 GPU: $GPU_NAME"
    if echo "$GPU_NAME" | grep -qiE 'RTX 50|B100|H100|Blackwell'; then
        IMAGE_TAG="cu130-slim-v2"
    elif echo "$GPU_NAME" | grep -qiE 'RTX 40|RTX 30|RTX 20|A100'; then
        IMAGE_TAG="cu128-slim"
    else
        IMAGE_TAG="cu126-slim"
    fi
    GPU_FLAG="--gpus all"
else
    warn "未检测到 N 卡驱动，将使用 CPU 模式"
    IMAGE_TAG="cpu"
fi

info "使用的镜像: ${IMAGE}:${IMAGE_TAG}"

read -rp "是否允许局域网访问? (y/N): " net_choice
if [[ "${net_choice:-N}" =~ ^[Yy]$ ]]; then
    BIND="0.0.0.0"
else
    BIND="127.0.0.1"
fi

read -rp "数据目录 [默认 $DEFAULT_DATA]: " data_dir
DATA_DIR="${data_dir:-$DEFAULT_DATA}"

info "创建目录: $DATA_DIR"
mkdir -p "$DATA_DIR"/{models,nodes,output,input}

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

info "启动容器..."
docker run -d \
    --name "$CONTAINER" \
    --restart always \
    $GPU_FLAG \
    -p "${BIND}:${DEFAULT_PORT}:8188" \
    -v "$DATA_DIR/models:/root/ComfyUI/models" \
    -v "$DATA_DIR/nodes:/root/ComfyUI/custom_nodes" \
    -v "$DATA_DIR/output:/root/ComfyUI/output" \
    -v "$DATA_DIR/input:/root/ComfyUI/input" \
    "${IMAGE}:${IMAGE_TAG}"

info "部署完成！访问地址: http://${BIND}:${DEFAULT_PORT}"
