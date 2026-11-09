#!/usr/bin/env bash
# ComfyUI Universal Installer V2.2.1 
# Linux x86_64 / AMD64 only
set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_VERSION="2.2.1"
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
DATA_DIR_CREATED=false
OLD_WAS_RUNNING=false
NEW_CONTAINER_CREATED=false
RUN_ATTEMPTED=false
RUN_LABEL_VALUE=""
TEMP_SCRIPT=""
ASK_OPTION_RESULT=""

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

# 从终端读取一行，结果写入调用者指定的变量（$2）。
# 必须以“直接调用”方式使用，不要放在命令替换里，否则 die 会在子 shell 中失效。
# 函数内不能声明与 $2 同名的 local 变量，否则 printf -v 会写入本地变量。
read_input() {
    local prompt="$1"
    local __outvar="$2"
    local __value

    if ! read -r -p "$prompt" __value; then
        die "$(msg "无法从终端读取输入，请以交互方式运行本脚本。" \
                    "Cannot read input from the terminal. Run this installer interactively.")"
    fi

    # 仅去除首尾空格，保留路径中间的合法空格。
    __value="${__value#"${__value%%[! ]*}"}"
    __value="${__value%"${__value##*[! ]}"}"
    printf -v "$__outvar" '%s' "$__value"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    while true; do
        if [[ "$default" == "y" ]]; then
            read_input "$prompt [Y/n]: " answer
            answer="${answer:-y}"
        else
            read_input "$prompt [y/N]: " answer
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf '%s\n' "$(msg "请输入 y 或 n。" "Please enter y or n.")" >&2 ;;
        esac
    done
}

# 结果写入全局 ASK_OPTION_RESULT，避免命令替换导致 die 在子 shell 中失效。
ask_option() {
    local prompt="$1"
    local default="$2"
    shift 2

    local answer
    local valid

    while true; do
        read_input "$prompt [$default]: " answer
        answer="${answer:-$default}"

        for valid in "$@"; do
            if [[ "$answer" == "$valid" ]]; then
                ASK_OPTION_RESULT="$answer"
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
        curl awk df findmnt ss realpath hostname date \
        mktemp mkdir dirname find sleep chmod rm id chown mv tr
    do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "$(msg "缺少必需命令：" "Missing required command:") $command_name"
    done
}

show_system_info() {
    echo
    echo "========================================"
    echo " ComfyUI Universal Installer v${INSTALLER_VERSION}"
    echo "========================================"
    echo "OS: ${PRETTY_NAME:-Linux}"
    echo "Architecture: $(uname -m)"
    echo "Kernel: $(uname -r)"
    echo

    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS 2>/dev/null || true
    fi

    echo
    df -hT / /home 2>/dev/null || true
    echo
}

# 规范化并校验数据目录，结果写入 $2。
# 拒绝：空路径、控制字符、.. 组件、规范化后为 /、系统关键路径。
# 符号链接会被 realpath -m 解析，因此 link -> /etc 这类路径会被拒绝。
normalize_data_path() {
    local raw="$1"
    local __outvar="$2"
    local normalized

    [[ -n "$raw" ]] ||
        die "$(msg "数据目录不能为空。" "Data directory cannot be empty.")"

    [[ "$raw" == /* ]] ||
        die "$(msg "数据目录必须使用绝对路径。" "Data directory must be an absolute path.")"

    if [[ "$raw" == *[$'\n\t\r']* ]]; then
        die "$(msg "数据目录不能包含换行、制表符或回车。" \
                    "Data directory cannot contain newline, tab or carriage return.")"
    fi

    if [[ "/$raw/" == */../* ]]; then
        die "$(msg "数据目录不能包含 .. 组件。" \
                    "Data directory cannot contain .. components.")"
    fi

    if [[ "$raw" == *:* ]]; then
        die "$(msg "数据目录不能包含冒号 :，否则 Docker 挂载参数无法正确解析。" \
                    "Data directory cannot contain ':' because Docker volume syntax would be ambiguous.")"
    fi

    normalized="$(realpath -m -- "$raw" 2>/dev/null)" ||
        die "$(msg "无法规范化数据目录路径。" \
                    "Could not normalize the data directory path.")"

    [[ -n "$normalized" ]] ||
        die "$(msg "无法规范化数据目录路径。" \
                    "Could not normalize the data directory path.")"

    [[ "$normalized" != "/" ]] ||
        die "$(msg "不能将 / 设置为数据目录。" \
                    "The root directory cannot be used as the data directory.")"

    case "$normalized" in
        /run/media/*) ;; # 常见桌面环境的可移动磁盘挂载点
        /etc|/etc/*|/usr|/usr/*|/var|/var/*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*)
            die "$(msg "数据目录不能位于系统关键路径下：$normalized" \
                        "Data directory cannot be under a system-critical path: $normalized")"
            ;;
    esac

    printf -v "$__outvar" '%s' "$normalized"
}

validate_data_path() {
    local path="$1"
    local parent
    local mount_target
    local available_kb
    local mount_source

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

    if [[ ! -e "$path" ]]; then
        DATA_DIR_CREATED=true
    fi

    mkdir -p "$path" ||
        die "$(msg "无法创建数据目录。" "Could not create the data directory.")"

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
    local default_path="${HOME:-/root}/ComfyUI-Docker"
    local answer
    local candidate

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

    read_input "[$default_path]: " answer
    candidate="${answer:-$default_path}"

    normalize_data_path "$candidate" DATA_DIR
}

check_docker() {
    local has_docker_cli=false
    local has_docker_service=false

    if command -v docker >/dev/null 2>&1; then
        has_docker_cli=true
        if docker info >/dev/null 2>&1; then
            ok "$(msg "Docker 已安装并运行。" "Docker is installed and running.")"
            return 0
        fi
        warn "$(msg "检测到 Docker 命令，但 Docker Engine 当前不可用。" \
                     "Docker CLI exists, but Docker Engine is unavailable.")"
        if systemctl cat docker.service >/dev/null 2>&1; then
            has_docker_service=true
            ask_yes_no \
                "$(msg "尝试启动现有 Docker 服务？" "Try starting the existing Docker service?")" \
                y || die "$(msg "请先修复现有 Docker 服务，再重新运行。" "Repair the existing Docker service before retrying.")"
            systemctl enable --now docker ||
                die "$(msg "无法启动现有 Docker 服务。" "Could not start the existing Docker service.")"
            docker info >/dev/null 2>&1 ||
                die "$(msg "Docker 服务启动后仍不可用。" "Docker is still unavailable after starting the service.")"
            ok "$(msg "现有 Docker 服务已启动。" "Existing Docker service started.")"
            return 0
        fi
    fi

    warn "$(msg "没有检测到可用的 Docker Engine。" "Docker Engine is not available.")"
    if [[ "$has_docker_cli" == true && "$has_docker_service" == false ]]; then
        warn "$(msg "检测到 Docker 命令，但未找到 docker.service。安装过程可能调整现有 Docker 组件。" \
                     "Docker CLI exists but docker.service was not found. Installing may modify existing Docker components.")"
    fi
    ask_yes_no \
        "$(msg "是否下载并运行 Docker 官方安装脚本？" "Download and run the official Docker installation script?")" \
        n || die "$(msg "请先安装或修复 Docker，再重新运行本脚本。" "Install or repair Docker, then rerun this installer.")"

    TEMP_SCRIPT="$(mktemp)" || die "$(msg "无法创建临时文件。" "Could not create a temporary file.")"
    if ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 2 --connect-timeout 15 --max-time 300 \
        https://get.docker.com -o "$TEMP_SCRIPT"; then
        die "$(msg "Docker 安装脚本下载失败。" "Docker installation script download failed.")"
    fi
    [[ -s "$TEMP_SCRIPT" ]] ||
        die "$(msg "Docker 安装脚本为空。" "Docker installation script is empty.")"
    if ! bash "$TEMP_SCRIPT"; then
        die "$(msg "Docker 官方安装脚本执行失败。" "The official Docker installation script failed.")"
    fi
    rm -f "$TEMP_SCRIPT"
    TEMP_SCRIPT=""

    systemctl enable --now docker ||
        die "$(msg "无法启动 Docker 服务。" "Could not start Docker service.")"
    docker info >/dev/null 2>&1 ||
        die "$(msg "Docker 安装后仍无法正常运行。" "Docker is still unavailable after installation.")"
    ok "$(msg "Docker 安装完成。" "Docker installation completed.")"
}

# Docker 镜像通常存储在 DockerRootDir（常在 /var/lib/docker），
# 可能与 DATA_DIR 不在同一分区，因此单独检查其可用空间。
check_docker_space() {
    local docker_root
    local available_kb
    local required_kb=$((15 * 1024 * 1024))  # 15 GiB，保守估计

    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"

    if [[ -z "$docker_root" || ! -d "$docker_root" ]]; then
        warn "$(msg "无法确定 Docker 存储目录，跳过 Docker 空间检查。" \
                     "Could not determine the Docker storage directory. Skipping Docker space check.")"
        return 0
    fi

    available_kb="$(df -Pk "$docker_root" 2>/dev/null | awk 'NR==2 {print $4}')"

    if [[ ! "$available_kb" =~ ^[0-9]+$ ]]; then
        warn "$(msg "无法确定 Docker 存储目录的可用空间，跳过检查。" \
                     "Could not determine free space under the Docker storage directory. Skipping check.")"
        return 0
    fi

    info "$(msg "Docker 存储目录：" "Docker storage directory:") $docker_root"
    info "$(msg "Docker 存储可用空间：约" "Docker storage free space: about") $(( available_kb / 1024 / 1024 )) GiB"

    if (( available_kb < required_kb )); then
        warn "$(msg "Docker 存储可用空间不足 15 GiB，镜像拉取可能失败。" \
                     "Less than 15 GiB is available under the Docker storage directory. Image pull may fail.")"
        ask_yes_no \
            "$(msg "仍然继续？" "Continue anyway?")" \
            n ||
            die "$(msg "已取消安装。" "Installation cancelled.")"
    fi
}

# 防止把 ComfyUI 数据目录放进 Docker 自身存储目录，或反过来覆盖 Docker 存储目录。
check_data_docker_path_conflict() {
    local docker_root
    local normalized_root

    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [[ -z "$docker_root" || "$docker_root" != /* ]]; then
        warn "$(msg "无法可靠识别 Docker 存储目录，跳过路径冲突检查。" \
                     "Could not reliably identify Docker storage path; skipping overlap check.")"
        return 0
    fi

    normalized_root="$(realpath -m -- "$docker_root" 2>/dev/null)" ||
        die "$(msg "无法规范化 Docker 存储目录。" "Could not normalize Docker storage directory.")"

    if [[ "$DATA_DIR" == "$normalized_root" ||
          "$DATA_DIR/" == "$normalized_root/"* ||
          "$normalized_root/" == "$DATA_DIR/"* ]]; then
        die "$(msg "ComfyUI 数据目录与 Docker 存储目录存在重叠：$DATA_DIR 与 $normalized_root。请更换数据目录。" \
                    "ComfyUI data directory overlaps Docker storage: $DATA_DIR and $normalized_root. Choose another data directory.")"
    fi
}

detect_nvidia() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

choose_image() {
    local gpu_info
    local gpu_names
    local min_cap
    local recommended=""
    local default_choice="2"
    local choice

    echo
    if ! detect_nvidia; then
        warn "$(msg "未检测到可用的 NVIDIA 驱动或 GPU。" "No working NVIDIA driver or GPU was detected.")"
        echo "$(msg "脚本不会安装或修改 NVIDIA 驱动。" "This installer will not install or modify NVIDIA drivers.")"
        ask_yes_no \
            "$(msg "是否继续安装 CPU 版本？" "Continue with the CPU-only image?")" \
            n || die "$(msg "已取消。请先在宿主机配置 NVIDIA 驱动，再重新运行。" \
                            "Cancelled. Configure the NVIDIA driver on the host, then rerun the installer.")"
        IMAGE_TAG="cpu"
        GPU_MODE="cpu"
        return 0
    fi

    gpu_info="$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits 2>/dev/null || true)"
    gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | awk 'NR==1 {out=$0; next} {out=out ", " $0} END {print out}' || true)"
    echo "$(msg "检测到 NVIDIA GPU：" "NVIDIA GPU detected:") ${gpu_names:-Unknown}"

    min_cap="$(printf '%s\n' "$gpu_info" | awk -F, '
        NF >= 2 {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            if ($2 ~ /^[0-9]+([.][0-9]+)?$/) {
                value = $2 + 0
                if (count == 0 || value < minimum) minimum = value
                count++
            }
        }
        END { if (count > 0) printf "%.1f", minimum }
    ')"

    if [[ -n "$min_cap" ]]; then
        if awk -v cap="$min_cap" 'BEGIN { exit !(cap >= 7.5) }'; then
            recommended="cu130-slim-v2"
            default_choice="1"
        else
            recommended="cu126-slim"
            default_choice="2"
        fi
        info "$(msg "检测到最低计算能力：" "Lowest detected compute capability:") $min_cap"
        info "$(msg "建议镜像：" "Recommended image:") $recommended"
    else
        warn "$(msg "无法读取 GPU 计算能力，将由你手动选择兼容镜像。" \
                     "Could not read GPU compute capability. Choose a compatible image manually.")"
    fi

    echo
    echo "1) cu130-slim-v2  ($(msg "建议用于 Turing 及更新架构" "Recommended for Turing and newer"))"
    echo "2) cu126-slim     ($(msg "兼容 Volta / Pascal / Maxwell 等旧架构" "Supports older architectures including Volta / Pascal / Maxwell"))"
    echo "3) cpu"
    echo
    ask_option "$(msg "选择镜像" "Select image")" "$default_choice" 1 2 3
    choice="$ASK_OPTION_RESULT"
    case "$choice" in
        1) IMAGE_TAG="cu130-slim-v2"; GPU_MODE="nvidia" ;;
        2) IMAGE_TAG="cu126-slim"; GPU_MODE="nvidia" ;;
        3) IMAGE_TAG="cpu"; GPU_MODE="cpu" ;;
    esac
}

check_nvidia_docker() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    local test_output
    local choice

    [[ "$GPU_MODE" == "nvidia" ]] || return 0

    echo
    info "$(msg "使用已下载的 ComfyUI 镜像测试 PyTorch GPU 透传……" \
                  "Testing PyTorch GPU passthrough using the downloaded ComfyUI image...")"

    if test_output="$(docker run --rm --runtime=nvidia --gpus all \
        --entrypoint python "$image" -c \
        'import torch; assert torch.cuda.is_available(), "CUDA is not available"; print(torch.cuda.get_device_name(0))' 2>&1)"; then
        ok "$(msg "Docker GPU 透传和 PyTorch CUDA 检查通过。" \
                   "Docker GPU passthrough and PyTorch CUDA check passed.")"
        printf '%s\n' "$test_output"
        return 0
    fi

    warn "$(msg "GPU 透传测试未通过。可能缺少或未正确配置 NVIDIA Container Toolkit，也可能是驱动与镜像不兼容。" \
                 "GPU passthrough test failed. NVIDIA Container Toolkit may be missing/misconfigured, or the driver may be incompatible with this image.")"
    printf '%s\n' "$test_output"
    echo "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    echo
    if [[ "$IMAGE_TAG" == "cu130-slim-v2" ]]; then
        echo "1) $(msg "改用 cu126-slim 重试 GPU 透传" "Retry GPU passthrough with cu126-slim")"
        echo "2) $(msg "改用 CPU 镜像继续安装" "Switch to the CPU image and continue")"
        echo "3) $(msg "取消安装，先修复 GPU 环境" "Cancel and fix the GPU environment first")"
        ask_option "$(msg "请选择" "Choose")" 3 1 2 3
        choice="$ASK_OPTION_RESULT"
        if [[ "$choice" == "1" ]]; then
            IMAGE_TAG="cu126-slim"
            pull_image
            info "$(msg "正在使用 cu126-slim 重新测试 GPU 透传……" "Retrying GPU passthrough with cu126-slim...")"
            if test_output="$(docker run --rm --runtime=nvidia --gpus all \
                --entrypoint python "${IMAGE_REPO}:${IMAGE_TAG}" -c \
                'import torch; assert torch.cuda.is_available(), "CUDA is not available"; print(torch.cuda.get_device_name(0))' 2>&1)"; then
                ok "$(msg "cu126-slim GPU 透传测试通过。" "cu126-slim GPU passthrough test passed.")"
                printf '%s\n' "$test_output"
                return 0
            fi
            warn "$(msg "cu126-slim GPU 透传仍未通过。" "cu126-slim GPU passthrough also failed.")"
            printf '%s\n' "$test_output"
            echo "1) $(msg "改用 CPU 镜像继续安装" "Switch to the CPU image and continue")"
            echo "2) $(msg "取消安装" "Cancel installation")"
            ask_option "$(msg "请选择" "Choose")" 2 1 2
            choice="$ASK_OPTION_RESULT"
            [[ "$choice" == "1" ]] || die "$(msg "已取消。请修复 GPU 环境后重试。" "Cancelled. Fix the GPU environment and retry.")"
        elif [[ "$choice" != "2" ]]; then
            die "$(msg "已取消。修复 NVIDIA Container Toolkit 后重新运行即可。" \
                        "Cancelled. Fix NVIDIA Container Toolkit and rerun the installer.")"
        fi
    else
        echo "1) $(msg "改用 CPU 镜像继续安装" "Switch to the CPU image and continue")"
        echo "2) $(msg "取消安装，先修复 GPU 环境" "Cancel and fix the GPU environment first")"
        ask_option "$(msg "请选择" "Choose")" 2 1 2
        choice="$ASK_OPTION_RESULT"
        [[ "$choice" == "1" ]] || die "$(msg "已取消。修复 NVIDIA Container Toolkit 后重新运行即可。" \
                    "Cancelled. Fix NVIDIA Container Toolkit and rerun the installer.")"
    fi

    IMAGE_TAG="cpu"
    GPU_MODE="cpu"
    pull_image
    warn "$(msg "已切换到 CPU 镜像。" "Switched to the CPU image.")"
}

choose_access_mode() {
    local choice
    local answer
    local port_number

    echo
    echo "$(msg "请选择访问方式：" "Choose access mode:")"
    echo "1) $(msg "仅本机访问" "Local access only")"
    echo "2) $(msg "局域网访问" "LAN access")"

    ask_option "$(msg "选择" "Select")" 1 1 2
    choice="$ASK_OPTION_RESULT"

    if [[ "$choice" == "1" ]]; then
        BIND_ADDR="127.0.0.1"
    else
        BIND_ADDR="0.0.0.0"
    fi

    read_input "$(msg "端口" "Port") [8188]: " answer
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
    local -a required_dirs=()
    local -a new_dirs=()
    local dir
    local backup_dir_created=false

    # cu130-slim-v2 使用拆分目录；cu126-slim 与 CPU 镜像使用 /root 持久化目录。
    if [[ "$IMAGE_TAG" == "cu130-slim-v2" ]]; then
        required_dirs+=(
            "$DATA_DIR/storage-cache/dot-cache"
            "$DATA_DIR/storage-cache/dot-config"
            "$DATA_DIR/storage-nodes/dot-local"
            "$DATA_DIR/storage-nodes/custom_nodes"
            "$DATA_DIR/storage-user/user-profile"
            "$DATA_DIR/storage-user/user-scripts"
        )
    else
        required_dirs+=(
            "$DATA_DIR/storage"
            "$DATA_DIR/storage-user/workflows"
        )
    fi

    required_dirs+=(
        "$DATA_DIR/storage-models/models"
        "$DATA_DIR/storage-models/hf-hub"
        "$DATA_DIR/storage-models/torch-hub"
        "$DATA_DIR/storage-user/input"
        "$DATA_DIR/storage-user/output"
        "$BACKUP_DIR"
    )

    # 检查目标位置是否被同名普通文件占用，避免 mkdir 失败到一半才发现。
    for dir in "${required_dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            [[ -d "$dir" ]] ||
                die "$(msg "预期目录位置已存在非目录文件：$dir" "A non-directory file exists where a directory is required: $dir")"
        else
            new_dirs+=("$dir")
            [[ "$dir" == "$BACKUP_DIR" ]] && backup_dir_created=true
        fi
    done

    mkdir -p "${required_dirs[@]}" ||
        die "$(msg "无法创建 ComfyUI 数据子目录。" "Could not create ComfyUI data subdirectories.")"

    [[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] ||
        die "$(msg "备份目录不可写。" "Backup directory is not writable.")"

    chmod 700 "$BACKUP_DIR" ||
        die "$(msg "无法将备份目录权限设置为 700，拒绝继续以免备份信息暴露。" \
                    "Could not set backup directory permissions to 700; refusing to continue with exposed backups.")"

    # 只调整本次新建目录的属主；不递归修改已有模型、插件或用户文件。
    if [[ -n "${SUDO_USER:-}" ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
        if [[ "$DATA_DIR_CREATED" == true ]]; then
            chown --from=root "$SUDO_USER:" "$DATA_DIR" 2>/dev/null || true
        fi
        for dir in "${new_dirs[@]}"; do
            chown --from=root "$SUDO_USER:" "$dir" 2>/dev/null || true
        done
    fi
}

# 判断旧版目录是否含有数据，用于兼容 V2.1.6 的拆分挂载，避免升级后旧插件/配置看起来丢失。
directory_has_entries() {
    [[ -d "$1" ]] &&
        [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

pull_image() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    local attempt

    echo
    info "$(msg "正在拉取镜像：" "Pulling image:") $image"

    for attempt in 1 2 3; do
        if command -v timeout >/dev/null 2>&1; then
            if timeout --signal=TERM --kill-after=30s 1800s docker pull "$image"; then
                ok "$(msg "镜像拉取成功。" "Image pulled successfully.")"
                return 0
            fi
        elif docker pull "$image"; then
            ok "$(msg "镜像拉取成功。" "Image pulled successfully.")"
            return 0
        fi

        warn "$(msg "拉取失败，准备重试：" "Pull failed. Retry:") ${attempt}/3"
        sleep $((attempt * 3))
    done

    die "$(msg "镜像拉取失败。请检查网络、Docker Hub 限流和 Registry Mirror。" \
                "Image pull failed. Check network, Docker Hub rate limits and registry mirror settings.")"
}

# 保存 docker inspect 输出，文件权限 600（可能含 Config.Env 等敏感信息）。
save_container_inspect() {
    local container="$1"
    local outfile="$2"
    local tmpfile

    [[ ! -e "$outfile" ]] || return 1

    tmpfile="$(mktemp "${outfile}.XXXXXX")" || return 1
    chmod 600 "$tmpfile" 2>/dev/null || true

    if ! docker inspect "$container" > "$tmpfile" 2>/dev/null; then
        rm -f "$tmpfile"
        return 1
    fi

    # 优先用硬链接原子发布；不支持硬链接的文件系统回退到同目录 mv -n。
    if ! ln -- "$tmpfile" "$outfile" 2>/dev/null; then
        if ! mv -n -- "$tmpfile" "$outfile" 2>/dev/null || [[ -e "$tmpfile" ]]; then
            rm -f "$tmpfile"
            return 1
        fi
    else
        rm -f "$tmpfile"
    fi

    chmod 600 "$outfile" 2>/dev/null || true
    return 0
}

backup_existing_container() {
    local base_name
    local suffix=0
    local state

    if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        return 0
    fi

    state="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" ||
        die "$(msg "无法读取旧容器运行状态，已取消替换。" "Could not read old container state; replacement aborted.")"

    [[ "$state" == "true" ]] && OLD_WAS_RUNNING=true || OLD_WAS_RUNNING=false

    base_name="${CONTAINER}-backup-$(date +%Y%m%d-%H%M%S)"
    OLD_CONTAINER="$base_name"
    BACKUP_DIR="$DATA_DIR/backups"

    # 同时避开已有容器名和已有 JSON 文件，绝不覆盖旧备份。
    while docker container inspect "$OLD_CONTAINER" >/dev/null 2>&1 ||
          [[ -e "$BACKUP_DIR/${OLD_CONTAINER}.json" ]]; do
        suffix=$((suffix + 1))
        OLD_CONTAINER="${base_name}-${suffix}"
    done

    warn "$(msg "发现同名容器，准备保留旧容器：" \
                 "Existing container found. It will be preserved as:") $OLD_CONTAINER"

    if ! save_container_inspect "$CONTAINER" "$BACKUP_DIR/${OLD_CONTAINER}.json"; then
        die "$(msg "无法保存旧容器配置，已停止替换。" \
                    "Could not save the old container configuration. Replacement aborted.")"
    fi

    if [[ "$OLD_WAS_RUNNING" == true ]]; then
        if ! docker stop -t 30 "$CONTAINER" >/dev/null; then
            die "$(msg "无法停止旧容器，已取消替换。" \
                        "Could not stop the old container. Replacement aborted.")"
        fi
    fi

    if ! docker rename "$CONTAINER" "$OLD_CONTAINER"; then
        if [[ "$OLD_WAS_RUNNING" == true ]]; then
            docker start "$CONTAINER" >/dev/null 2>&1 || true
        fi
        die "$(msg "无法重命名旧容器，已尝试恢复原状态。" \
                    "Could not rename old container; attempted to restore its original state.")"
    fi

    ok "$(msg "旧容器已保留。" "Previous container preserved.")"
}

run_container() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    local -a docker_args
    local new_json

    RUN_LABEL_VALUE="comfyui-installer-$$-$(date +%s)"
    docker_args=(
        run -d
        --name "$CONTAINER"
        --label "com.openai.comfyui-installer-run=$RUN_LABEL_VALUE"
        --restart unless-stopped
        -p "${BIND_ADDR}:${PORT}:8188"
    )

    if [[ "$IMAGE_TAG" == "cu130-slim-v2" ]]; then
        docker_args+=(
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
        )
    elif [[ "$IMAGE_TAG" == "cu126-slim" || "$IMAGE_TAG" == "cpu" ]]; then
        docker_args+=(
            -v "$DATA_DIR/storage:/root"
            -v "$DATA_DIR/storage-models/models:/root/ComfyUI/models"
            -v "$DATA_DIR/storage-models/hf-hub:/root/.cache/huggingface/hub"
            -v "$DATA_DIR/storage-models/torch-hub:/root/.cache/torch/hub"
            -v "$DATA_DIR/storage-user/input:/root/ComfyUI/input"
            -v "$DATA_DIR/storage-user/output:/root/ComfyUI/output"
            -v "$DATA_DIR/storage-user/workflows:/root/ComfyUI/user/default/workflows"
        )

        # 若复用 V2.1.6 的数据目录，只把确实已有内容的旧目录继续挂载；
        # 新安装则全部保存在 /root 对应的 storage 目录中。
        if directory_has_entries "$DATA_DIR/storage-cache/dot-cache"; then
            docker_args+=(-v "$DATA_DIR/storage-cache/dot-cache:/root/.cache")
        fi
        if directory_has_entries "$DATA_DIR/storage-cache/dot-config"; then
            docker_args+=(-v "$DATA_DIR/storage-cache/dot-config:/root/.config")
        fi
        if directory_has_entries "$DATA_DIR/storage-nodes/dot-local"; then
            docker_args+=(-v "$DATA_DIR/storage-nodes/dot-local:/root/.local")
        fi
        if directory_has_entries "$DATA_DIR/storage-nodes/custom_nodes"; then
            docker_args+=(-v "$DATA_DIR/storage-nodes/custom_nodes:/root/ComfyUI/custom_nodes")
        fi
        if directory_has_entries "$DATA_DIR/storage-user/user-profile"; then
            docker_args+=(-v "$DATA_DIR/storage-user/user-profile:/root/ComfyUI/user")
        fi
        if directory_has_entries "$DATA_DIR/storage-user/user-scripts"; then
            docker_args+=(-v "$DATA_DIR/storage-user/user-scripts:/root/user-scripts")
        fi
    fi

    if [[ "$GPU_MODE" == "nvidia" ]]; then
        docker_args+=(-e CLI_ARGS="" --runtime=nvidia --gpus all)
    fi
    docker_args+=("$image")

    # 记录本次创建尝试。docker run 即使返回非零，也可能已留下同名容器。
    RUN_ATTEMPTED=true
    if ! docker "${docker_args[@]}"; then
        return 1
    fi
    NEW_CONTAINER_CREATED=true

    local stamp
    local suffix=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    new_json="$BACKUP_DIR/${CONTAINER}-new-${stamp}.json"
    while [[ -e "$new_json" ]]; do
        suffix=$((suffix + 1))
        new_json="$BACKUP_DIR/${CONTAINER}-new-${stamp}-${suffix}.json"
    done
    if ! save_container_inspect "$CONTAINER" "$new_json"; then
        warn "$(msg "无法保存新容器配置备份，但容器已启动。" \
                     "Could not save the new container configuration backup, but the container is running.")"
    fi
}

wait_for_comfyui() {
    local attempt

    info "$(msg "等待 ComfyUI 启动，最长约 600 秒……" \
                  "Waiting for ComfyUI, up to approximately 600 seconds...")"

    for ((attempt=1; attempt<=120; attempt++)); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]] &&
           curl -fsS --max-time 4 \
            "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1
        then
            ok "$(msg "ComfyUI HTTP 健康检查通过。" \
                       "ComfyUI HTTP health check passed.")"
            return 0
        fi

        if (( attempt % 12 == 0 )); then
            info "$(msg "仍在等待 ComfyUI 启动……已等待" "Still waiting for ComfyUI... elapsed:") $((attempt * 5))s"
        fi
        sleep 5
    done

    return 1
}

# 回滚流程：
#   1. 删除新容器；若删除失败则中止回滚（否则重命名会与现存容器冲突）。
#   2. 把旧容器名改回原名。
#   3. 启动旧容器并轮询验证其确实在运行。
# 所有分支都返回 0，错误通过 warn 输出；调用方在之后 die，避免 set -e 提前退出。
rollback_container() {
    local old_renamed=0
    local old_running=0
    local attempt

    warn "$(msg "新容器未成功启动或未通过健康检查，正在尝试回滚。" \
                 "New container failed to start or failed health check. Attempting rollback.")"

    # 旧容器已改名后，原名称只可能属于本次 docker run 尝试留下的新容器。
    # 即使 docker run 返回非零，也检查并清理可能已创建但未启动的容器。
    if [[ "$RUN_ATTEMPTED" == true ]] && docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        local found_run_label
        found_run_label="$(docker inspect -f '{{ index .Config.Labels "com.openai.comfyui-installer-run" }}' "$CONTAINER" 2>/dev/null || true)"
        if [[ "$found_run_label" != "$RUN_LABEL_VALUE" || -z "$RUN_LABEL_VALUE" ]]; then
            warn "$(msg "检测到同名容器，但无法确认它由本次安装创建。为防止误删，已停止自动回滚。" \
                         "A same-name container exists but cannot be verified as created by this installer run. Automatic rollback stopped to prevent accidental deletion.")"
            echo "  docker ps -a"
            if [[ -n "$OLD_CONTAINER" ]]; then echo "  docker rename $OLD_CONTAINER $CONTAINER"; fi
            return 0
        fi
        docker logs --tail 120 "$CONTAINER" 2>&1 || true

        if ! docker rm -f "$CONTAINER" >/dev/null 2>&1; then
            warn "$(msg "无法删除本次创建的新容器，自动回滚中止。请手动处理：" \
                         "Could not remove the new container created by this run. Automatic rollback aborted. Handle manually:")"
            echo "  docker logs $CONTAINER"
            echo "  docker rm -f $CONTAINER"
            if [[ -n "$OLD_CONTAINER" ]]; then echo "  docker rename $OLD_CONTAINER $CONTAINER"; fi
            return 0
        fi
    fi

    # 恢复旧容器名称。
    if [[ -n "$OLD_CONTAINER" ]] && docker container inspect "$OLD_CONTAINER" >/dev/null 2>&1; then
        if docker rename "$OLD_CONTAINER" "$CONTAINER"; then
            old_renamed=1
        else
            warn "$(msg "无法将备份容器 $OLD_CONTAINER 重命名为 $CONTAINER。" \
                         "Could not rename backup container $OLD_CONTAINER back to $CONTAINER.")"
        fi
    fi

    # 只恢复原本正在运行的容器；原本停止的容器继续保持停止。
    if (( old_renamed == 1 )); then
        if [[ "$OLD_WAS_RUNNING" == true ]]; then
            if docker start "$CONTAINER" >/dev/null 2>&1; then
                for attempt in 1 2 3 4 5; do
                    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == "true" ]]; then
                        old_running=1
                        break
                    fi
                    sleep 2
                done
            fi
        else
            old_running=1
        fi
    fi

    if (( old_running == 1 )) && [[ "$OLD_WAS_RUNNING" == true ]]; then
        ok "$(msg "回滚完成，旧容器已恢复运行。" \
                   "Rollback completed; the previous container is running again.")"
    elif (( old_running == 1 )); then
        ok "$(msg "回滚完成，旧容器保持原来的停止状态。" \
                   "Rollback completed; the previous container remains stopped as before.")"
    elif (( old_renamed == 1 )); then
        warn "$(msg "旧容器已恢复名称但未能确认运行。请检查：" \
                     "The previous container was renamed back but could not be confirmed running. Check:")"
        echo "  docker ps -a"
        echo "  docker logs $CONTAINER"
    elif [[ -n "$OLD_CONTAINER" ]]; then
        warn "$(msg "旧容器保留为 $OLD_CONTAINER，未能自动恢复。请手动处理。" \
                     "The previous container is preserved as $OLD_CONTAINER and was not restored automatically. Handle manually.")"
    else
        ok "$(msg "没有旧容器需要恢复。" "No previous container needed restoration.")"
    fi

    return 0
}

show_result() {
    local lan_ip
    local url_host

    lan_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk 'index($0, ":") == 0 && $0 !~ /^127\./ {print; exit}')"

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
            url_host="${lan_ip:-$(msg "服务器局域网IP" "server LAN IP")}"
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
        echo "docker rm -f $OLD_CONTAINER"
    fi
}

cleanup_temp_script() {
    if [[ -n "${TEMP_SCRIPT:-}" ]]; then
        rm -f -- "$TEMP_SCRIPT" 2>/dev/null || true
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
    check_data_docker_path_conflict
    validate_data_path "$DATA_DIR"
    choose_image
    choose_access_mode

    # 先检查 Docker 存储空间并拉取目标镜像，再用该镜像验证 GPU，避免额外下载测试镜像。
    check_docker_space
    pull_image
    check_nvidia_docker

    # GPU 检查可能选择切换到 CPU 镜像，因此在镜像最终确定后再创建对应目录。
    prepare_data_directories

    # 只有环境检查和镜像准备全部通过后，才移动旧容器。
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

trap cleanup_temp_script EXIT
main "$@"
