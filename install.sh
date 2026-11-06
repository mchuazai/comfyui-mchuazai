from pathlib import Path

script = r'''#!/usr/bin/env bash
# ComfyUI Universal Installer V2.1.2
# Linux x86_64 / AMD64 only
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.1.2"
IMAGE_REPO="yanwk/comfyui-boot"
CONTAINER="comfyui"
DATA_DIR=""
IMAGE_TAG=""
GPU_MODE="cpu"
BIND_ADDR="127.0.0.1"
PORT="8188"
OLD_CONTAINER=""
LANG_CODE="en"
BACKUP_DIR=""

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
RESET=$'\033[0m'

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

msg() {
    if [[ "$LANG_CODE" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

detect_language() {
    local locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    [[ "$locale" == zh* ]] && LANG_CODE="zh" || LANG_CODE="en"
}

# 从终端读取一行；非交互环境（stdin 不可读）时直接失败，避免静默使用默认值。
read_input() {
    local prompt="$1"
    local answer

    if ! read -r -p "$prompt" answer; then
        die "$(msg "无法从终端读取输入，请以交互方式运行本脚本。" \
                    "Cannot read input from the terminal. Run this installer interactively.")"
    fi

    printf '%s' "$answer"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    while true; do
        if [[ "$default" == "y" ]]; then
            answer="$(read_input "$prompt [Y/n]: ")"
            answer="${answer:-y}"
        else
            answer="$(read_input "$prompt [y/N]: ")"
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf '%s\n' "$(msg "请输入 y 或 n。" "Please enter y or n.")" >&2 ;;
        esac
    done
}

ask_option() {
    local prompt="$1"
    local default="$2"
    shift 2

    local answer
    local valid

    while true; do
        answer="$(read_input "$prompt [$default]: ")"
        answer="${answer:-$default}"

        for valid in "$@"; do
            if [[ "$answer" == "$valid" ]]; then
                printf '%s' "$answer"
                return 0
            fi
        done

        printf '%s\n' "$(msg "选项无效，请重新输入。" "Invalid option. Try again.")" >&2
    done
}

require_root() {
    [[ "$EUID" -eq 0 ]] ||
        die "$(msg "请使用 sudo 运行：sudo bash install.sh" \
                    "Run with sudo: sudo bash install.sh")"
}

check_system() {
    [[ "$(uname -m)" == "x86_64" ]] ||
        die "$(msg "仅支持 x86_64 / AMD64，不支持 ARM64。" \
                    "Only x86_64 / AMD64 is supported. ARM64 is unsupported.")"

    [[ -r /etc/os-release ]] ||
        die "$(msg "无法识别 Linux 发行版。" \
                    "Cannot identify Linux distribution.")"

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|fedora|rhel|centos|rocky|almalinux)
            ;;
        *)
            die "$(msg "当前发行版不在支持列表中。" \
                        "This Linux distribution is not in the supported list.")"
            ;;
    esac

    command -v systemctl >/dev/null 2>&1 ||
        die "$(msg "当前系统需要 systemd。" \
                    "This installer requires systemd.")"

    systemctl is-system-running >/dev/null 2>&1 ||
        warn "$(msg "systemd 当前状态不是正常运行状态，请留意后续服务操作。" \
                    "systemd is not reporting a fully running state.")"
}

check_commands() {
    local command_name

    for command_name in \
        curl awk grep sed df findmnt ss head getent \
        hostname date mktemp mkdir dirname find \
        lsblk sleep seq chmod
    do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "$(msg "缺少必需命令：" "Missing required command:") $command_name"
    done
}

show_system_info() {
    echo
    echo "========================================"
    echo " ComfyUI Universal Installer v${VERSION}"
    echo "========================================"
    echo "OS: ${PRETTY_NAME:-Linux}"
    echo "Architecture: $(uname -m)"
    echo "Kernel: $(uname -r)"
    echo

    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS 2>/dev/null || true

    echo
    df -hT / /home 2>/dev/null || true
    echo
}

validate_data_path() {
    local path="$1"
    local parent
    local mount_target
    local available_kb
    local mount_source

    [[ "$path" == /* ]] ||
        die "$(msg "数据目录必须使用绝对路径。" \
                    "Data directory must be an absolute path.")"

    [[ "$path" != "/" ]] ||
        die "$(msg "不能将 / 设置为数据目录。" \
                    "The root directory cannot be used as the data directory.")"

    # 在创建任何目录前，先解析最近的已存在祖先目录。
    parent="$path"
    while [[ ! -e "$parent" && "$parent" != "/" ]]; do
        parent="$(dirname "$parent")"
    done

    mount_target="$(findmnt -n -o TARGET -T "$parent" 2>/dev/null || true)"
    mount_source="$(findmnt -n -o SOURCE -T "$parent" 2>/dev/null || true)"

    [[ -n "$mount_target" ]] ||
        die "$(msg "无法识别数据目录所在的挂载点。" \
                    "Cannot identify the filesystem mount point.")"

    echo
    info "$(msg "目标路径所在挂载点：" "Filesystem mount point:") $mount_target"
    info "$(msg "存储设备：" "Storage device:") $mount_source"

    if [[ "$mount_target" == "/" ]]; then
        warn "$(msg "该目录位于系统根分区。如果你原本打算使用独立数据盘，请先确认数据盘已经挂载。" \
                     "This directory is on the root filesystem. If you intended to use a separate data disk, verify that it is mounted.")"

        ask_yes_no \
            "$(msg "确认继续使用当前文件系统？" \
                    "Continue using this filesystem?")" \
            n ||
            die "$(msg "已取消安装。" "Installation cancelled.")"
    fi

    mkdir -p "$path"

    [[ -d "$path" && -w "$path" ]] ||
        die "$(msg "数据目录不可写。" "Data directory is not writable.")"

    available_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"

    [[ "$available_kb" =~ ^[0-9]+$ ]] ||
        die "$(msg "无法确定可用磁盘空间。" \
                    "Unable to determine available disk space.")"

    if (( available_kb < 10485760 )); then
        warn "$(msg "剩余空间不足 10 GiB，下载镜像和模型前请确认容量。" \
                     "Less than 10 GiB is available. Check disk capacity before downloading models.")"
    fi

    if [[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        warn "$(msg "目录中已有文件，安装程序不会删除它们。" \
                     "The directory already contains files. They will not be deleted.")"
    fi
}

choose_data_directory() {
    local default_path="${HOME}/ComfyUI-Docker"
    local answer

    # 通过 sudo 调用时，优先使用调用者的家目录。
    if [[ -n "${SUDO_USER:-}" ]] && command -v getent >/dev/null 2>&1; then
        local user_home
        user_home="$(getent passwd "$SUDO_USER" | awk -F: '{print $6}')"
        [[ -n "$user_home" ]] && default_path="${user_home}/ComfyUI-Docker"
    fi

    echo
    echo "$(msg "请输入 ComfyUI 数据存储目录。" \
                  "Choose the ComfyUI data directory.")"
    echo "$(msg "建议使用已经挂载好的独立数据盘。" \
                  "A mounted data disk is recommended.")"

    answer="$(read_input "[$default_path]: ")"
    DATA_DIR="${answer:-$default_path}"

    validate_data_path "$DATA_DIR"
}

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            ok "$(msg "Docker 已安装并运行。" "Docker is installed and running.")"
            return 0
        fi

        warn "$(msg "检测到 Docker 命令，但 Docker Engine 当前不可用。" \
                     "Docker is installed, but the Docker Engine is unavailable.")"

        if systemctl list-unit-files docker.service >/dev/null 2>&1; then
            ask_yes_no \
                "$(msg "尝试启动现有 Docker 服务？" \
                        "Try starting the existing Docker service?")" \
                y || die "$(msg "请先修复现有 Docker 服务，再重新运行。" \
                                "Repair the existing Docker service before retrying.")"

            systemctl enable --now docker ||
                die "$(msg "无法启动现有 Docker 服务。" \
                            "Could not start the existing Docker service.")"

            docker info >/dev/null 2>&1 ||
                die "$(msg "Docker 服务启动后仍不可用。" \
                            "Docker is still unavailable after starting the service.")"
            return 0
        fi
    fi

    warn "$(msg "没有检测到可用的 Docker Engine。" \
                 "Docker Engine is not available.")"

    ask_yes_no \
        "$(msg "是否下载并运行 Docker 官方安装脚本？" \
                "Download and run the official Docker installation script?")" \
        n ||
        die "$(msg "请先安装 Docker，再重新运行本脚本。" \
                    "Install Docker first, then rerun this installer.")"

    local temp_script
    temp_script="$(mktemp)"

    if ! curl -fL --retry 2 --connect-timeout 15 \
        https://get.docker.com -o "$temp_script"; then
        rm -f "$temp_script"
        die "$(msg "Docker 安装脚本下载失败。" \
                    "Docker installation script download failed.")"
    fi

    [[ -s "$temp_script" ]] || {
        rm -f "$temp_script"
        die "$(msg "Docker 安装脚本为空。" \
                    "Docker installation script is empty.")"
    }

    if ! bash "$temp_script"; then
        rm -f "$temp_script"
        die "$(msg "Docker 官方安装脚本执行失败。" \
                    "The Docker installation script failed.")"
    fi

    rm -f "$temp_script"

    systemctl enable --now docker ||
        die "$(msg "无法启动 Docker 服务。" "Could not start Docker service.")"

    docker info >/dev/null 2>&1 ||
        die "$(msg "Docker 安装后仍无法正常运行。" \
                    "Docker is still unavailable after installation.")"

    ok "$(msg "Docker 安装完成。" "Docker installation completed.")"
}

detect_nvidia() {
    command -v nvidia-smi >/dev/null 2>&1 &&
        nvidia-smi -L >/dev/null 2>&1
}

choose_image() {
    local choice
    local gpu_name

    echo

    if detect_nvidia; then
        gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"

        echo "$(msg "检测到 NVIDIA GPU：" "NVIDIA GPU detected:") ${gpu_name:-Unknown}"
        echo
        echo "1) cu130-slim-v2"
        echo "   Blackwell / Hopper / Ada / Ampere / Turing"
        echo
        echo "2) cu126-slim"
        echo "   Volta / Pascal / Maxwell"
        echo
        echo "3) cpu"
        echo "   CPU only"
        echo

        choice="$(ask_option "$(msg "选择镜像" "Select image")" 1 1 2 3)"

        case "$choice" in
            1)
                IMAGE_TAG="cu130-slim-v2"
                GPU_MODE="nvidia"
                ;;
            2)
                IMAGE_TAG="cu126-slim"
                GPU_MODE="nvidia"
                ;;
            3)
                IMAGE_TAG="cpu"
                GPU_MODE="cpu"
                ;;
        esac
    else
        warn "$(msg "未检测到可用 NVIDIA 驱动，将使用 CPU 镜像。" \
                     "No working NVIDIA driver detected. CPU image will be used.")"

        IMAGE_TAG="cpu"
        GPU_MODE="cpu"
    fi
}

check_nvidia_docker() {
    [[ "$GPU_MODE" == "nvidia" ]] || return 0

    echo
    info "$(msg "检查 Docker NVIDIA GPU 透传能力……" \
                  "Checking Docker NVIDIA GPU passthrough...")"

    if docker run --rm --gpus all \
        nvidia/cuda:12.6.3-base-ubuntu22.04 \
        nvidia-smi >/dev/null 2>&1
    then
        ok "$(msg "Docker GPU 透传测试通过。" \
                   "Docker GPU passthrough test passed.")"
    else
        warn "$(msg "Docker GPU 透传测试失败。可能缺少 NVIDIA Container Toolkit 或配置不正确。" \
                     "Docker GPU passthrough test failed. NVIDIA Container Toolkit may be missing or misconfigured.")"

        echo "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"

        ask_yes_no \
            "$(msg "仍然尝试部署 ComfyUI 吗？" \
                    "Attempt ComfyUI deployment anyway?")" \
            n ||
            die "$(msg "请先配置 NVIDIA Container Toolkit 后重试。" \
                        "Configure NVIDIA Container Toolkit and retry.")"
    fi
}

choose_access_mode() {
    local choice
    local answer
    local port_number

    echo
    echo "$(msg "请选择访问方式：" "Choose access mode:")"
    echo "1) $(msg "仅本机访问" "Local access only")"
    echo "2) $(msg "局域网访问" "LAN access")"

    choice="$(ask_option "$(msg "选择" "Select")" 1 1 2)"

    if [[ "$choice" == "1" ]]; then
        BIND_ADDR="127.0.0.1"
    else
        BIND_ADDR="0.0.0.0"
    fi

    answer="$(read_input "$(msg "端口" "Port") [8188]: ")"
    answer="${answer:-8188}"

    [[ "$answer" =~ ^[0-9]{1,5}$ ]] ||
        die "$(msg "端口必须是 1 到 65535 的整数。" \
                    "Port must be an integer between 1 and 65535.")"

    # 强制按十进制解析，避免前导零被当作八进制。
    port_number=$((10#$answer))
    (( port_number >= 1 && port_number <= 65535 )) ||
        die "$(msg "端口必须是 1 到 65535 的整数。" \
                    "Port must be an integer between 1 and 65535.")"
    PORT="$port_number"

    if ss -H -ltn 2>/dev/null |
        awk -v p=":${PORT}" '$4 ~ (p "$") {found=1} END {exit !found}'
    then
        die "$(msg "端口已被占用，请更换端口。" \
                    "Port is already in use. Choose another port.")"
    fi
}

prepare_data_directories() {
    BACKUP_DIR="$DATA_DIR/backups"

    mkdir -p \
        "$DATA_DIR/storage-cache/dot-cache" \
        "$DATA_DIR/storage-cache/dot-config" \
        "$DATA_DIR/storage-nodes/dot-local" \
        "$DATA_DIR/storage-nodes/custom_nodes" \
        "$DATA_DIR/storage-models/models" \
        "$DATA_DIR/storage-models/hf-hub" \
        "$DATA_DIR/storage-models/torch-hub" \
        "$DATA_DIR/storage-user/input" \
        "$DATA_DIR/storage-user/output" \
        "$DATA_DIR/storage-user/user-profile" \
        "$DATA_DIR/storage-user/user-scripts" \
        "$BACKUP_DIR"

    [[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] ||
        die "$(msg "备份目录不可写。" "Backup directory is not writable.")"

    # 通过 sudo 运行时，把数据目录交还给调用者，便于其后续管理文件。
    if [[ -n "${SUDO_USER:-}" ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
        chown -R "$SUDO_USER:" "$DATA_DIR" 2>/dev/null ||
            warn "$(msg "无法将数据目录所有者改为 ${SUDO_USER}，后续可能需要 sudo 才能管理文件。" \
                         "Could not change the data directory owner to ${SUDO_USER}. sudo may be required to manage files.")"
    fi
}

pull_image() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    local attempt

    echo
    info "$(msg "正在拉取镜像：" "Pulling image:") $image"

    for attempt in 1 2 3; do
        if docker pull "$image"; then
            ok "$(msg "镜像拉取成功。" "Image pulled successfully.")"
            return 0
        fi

        warn "$(msg "拉取失败，准备重试：" "Pull failed. Retry:") ${attempt}/3"
        sleep $((attempt * 3))
    done

    die "$(msg "镜像拉取失败。请检查网络、Docker Hub 限流和 Registry Mirror。" \
                "Image pull failed. Check network, Docker Hub rate limits and registry mirror settings.")"
}

backup_existing_container() {
    if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        return 0
    fi

    OLD_CONTAINER="${CONTAINER}-backup-$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$DATA_DIR/backups"

    # 避免与更早的备份容器名冲突。
    if docker container inspect "$OLD_CONTAINER" >/dev/null 2>&1; then
        OLD_CONTAINER="${OLD_CONTAINER}-$$"
    fi

    warn "$(msg "发现同名容器，准备保留旧容器：" \
                 "Existing container found. It will be preserved as:") $OLD_CONTAINER"

    docker inspect "$CONTAINER" \
        > "$BACKUP_DIR/${OLD_CONTAINER}.json" ||
        die "$(msg "无法保存旧容器配置，已停止替换。" \
                    "Could not save the old container configuration. Replacement aborted.")"

    if ! docker stop -t 30 "$CONTAINER" >/dev/null; then
        die "$(msg "无法停止旧容器，已取消替换。" \
                    "Could not stop the old container. Replacement aborted.")"
    fi

    if ! docker rename "$CONTAINER" "$OLD_CONTAINER"; then
        docker start "$CONTAINER" >/dev/null 2>&1 || true
        die "$(msg "无法重命名旧容器，已尝试重新启动旧容器。" \
                    "Could not rename the old container. Attempted to restart it.")"
    fi

    ok "$(msg "旧容器已保留。" "Previous container preserved.")"
}

run_container() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    local -a docker_args

    docker_args=(
        run -d
        --name "$CONTAINER"
        --restart unless-stopped
        -p "${BIND_ADDR}:${PORT}:8188"
        -v "$DATA_DIR/storage-cache/dot-cache:/root/.cache"
        -v "$DATA_DIR/storage-cache/dot-config:/root/.config"
        -v "$DATA_DIR/storage-nodes/dot-local:/root/.local"
        -v "$DATA_DIR/storage-nodes/custom_nodes:/root/ComfyUI/custom_nodes"
        -v "$DATA_DIR/storage-models/models:/root/ComfyUI/models"
        -v "$DATA_DIR/storage-models/hf-hub:/root/.cache/huggingface/hub"
        -v "$DATA_DIR/storage-models/torch-hub:/root/.cache/torch/hub"
        -v "$DATA_DIR/storage-user/input:/root/ComfyUI/input"
        -v "$DATA_DIR/storage-user/output:/root/ComfyUI/output"
        -v "$DATA_DIR/storage-user/user-profile:/root/ComfyUI/user"
        -v "$DATA_DIR/storage-user/user-scripts:/root/user-scripts"
        -e CLI_ARGS=""
    )

    if [[ "$GPU_MODE" == "nvidia" ]]; then
        docker_args+=(--gpus all)
    fi

    docker_args+=("$image")

    if ! docker "${docker_args[@]}"; then
        return 1
    fi

    # 备份失败只告警，不回滚：容器已成功启动，不应因备份问题丢弃它。
    docker inspect "$CONTAINER" \
        > "$BACKUP_DIR/${CONTAINER}-new-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null ||
        warn "$(msg "无法保存新容器配置备份，但容器已启动。" \
                     "Could not save the new container configuration backup, but the container is running.")"
}

wait_for_comfyui() {
    local attempt

    info "$(msg "等待 ComfyUI 启动，最长约 180 秒……" \
                  "Waiting for ComfyUI, up to approximately 180 seconds...")"

    for ((attempt=1; attempt<=36; attempt++)); do
        if curl -fsS --max-time 4 \
            "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1
        then
            ok "$(msg "ComfyUI HTTP 健康检查通过。" \
                       "ComfyUI HTTP health check passed.")"
            return 0
        fi

        sleep 5
    done

    return 1
}

rollback_container() {
    local rollback_ok=1

    warn "$(msg "新容器未成功启动或未通过健康检查，正在尝试回滚。" \
                 "New container failed to start or failed health check. Attempting rollback.")"

    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        docker logs --tail 120 "$CONTAINER" 2>&1 || true
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || rollback_ok=0
    fi

    if [[ -n "$OLD_CONTAINER" ]] &&
       docker container inspect "$OLD_CONTAINER" >/dev/null 2>&1
    then
        if docker rename "$OLD_CONTAINER" "$CONTAINER"; then
            docker start "$CONTAINER" || rollback_ok=0
        else
            rollback_ok=0
            warn "$(msg "无法恢复旧容器名称，请手动检查 docker ps -a。" \
                         "Could not restore the old container name. Check docker ps -a manually.")"
        fi
    fi

    if (( rollback_ok == 1 )); then
        ok "$(msg "回滚操作已完成。" "Rollback operation completed.")"
    else
        warn "$(msg "自动回滚未能完全完成，请检查容器状态。" \
                     "Automatic rollback was incomplete. Check container status.")"
    fi
}

show_result() {
    local lan_ip
    local url_host

    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    echo
    echo "========================================"
    ok "$(msg "ComfyUI 部署完成！" "ComfyUI deployment completed!")"
    echo "========================================"
    echo "$(msg "镜像：" "Image:") ${IMAGE_REPO}:${IMAGE_TAG}"
    echo "$(msg "数据目录：" "Data directory:") $DATA_DIR"

    if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
        echo "URL: http://127.0.0.1:${PORT}"
    else
        if [[ "$lan_ip" == *:* ]]; then
            url_host="[${lan_ip}]"
        else
            url_host="${lan_ip:-服务器局域网IP}"
        fi
        echo "URL: http://${url_host}:${PORT}"
        warn "$(msg "局域网模式监听所有网卡。请勿直接暴露到公网。" \
                     "LAN mode listens on all interfaces. Do not expose it directly to the Internet.")"
    fi

    echo
    echo "$(msg "查看日志：" "View logs:") docker logs -f $CONTAINER"
    echo "$(msg "重启容器：" "Restart:") docker restart $CONTAINER"
    echo "$(msg "停止容器：" "Stop:") docker stop $CONTAINER"

    if [[ -n "$OLD_CONTAINER" ]]; then
        echo
        warn "$(msg "旧容器仍保留，确认新容器正常后再手动清理：" \
                     "The old container is preserved. Remove it manually only after verifying the new one:")"
        echo "docker ps -a"
    fi
}

main() {
    detect_language
    require_root
    check_system
    check_commands
    show_system_info

    choose_data_directory
    check_docker
    choose_image
    choose_access_mode

    prepare_data_directories
    pull_image
    check_nvidia_docker

    backup_existing_container

    if ! run_container; then
        rollback_container
        die "$(msg "新容器启动失败，已执行回滚尝试。" \
                    "New container failed to start. Rollback was attempted.")"
    fi

    if ! wait_for_comfyui; then
        rollback_container
        die "$(msg "部署失败。请检查上方容器日志。" \
                    "Deployment failed. Review the container logs above.")"
    fi

    show_result
}

main "$@"
'''

path = Path("/mnt/data/install.sh")
path.write_text(script, encoding="utf-8")
print(f"已生成：{path}（{len(script.splitlines())} 行）")
