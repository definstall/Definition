#!/bin/bash

# ==============================================================================
# !!! 严重安全警告 !!!
# 此脚本已根据用户要求修改为以 ROOT 用户运行 FRP 服务。
# 以 ROOT 用户运行任何网络服务都存在巨大的安全风险。
# 如果 FRP 服务存在漏洞，攻击者将能够完全控制你的系统。
# 强烈建议在生产环境或任何对外暴露的服务器上，不要以 ROOT 用户运行 FRP。
# 请务必了解并承担由此带来的所有安全风险。
# ==============================================================================

# FRP 版本信息
FRP_VERSION="0.63.0"
FRP_DOWNLOAD_URL_AMD64="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
FRP_DOWNLOAD_URL_ARM64="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_arm64.tar.gz" # 新增：用于 arm64 (aarch64) 架构
FRP_DOWNLOAD_URL_ARMV7="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_arm.tar.gz" # 修正：用于 armv7 架构

# 安装路径 (FRP 二进制文件和配置文件都将在此目录)
INSTALL_DIR="/etc/frp" # 更改为 /etc/frp
CONFIG_DIR="/etc/frp" # 配置文件目录与二进制文件目录相同
LOG_DIR="/var/log/frp"
SYSTEMD_DIR="/etc/systemd/system"

# 默认认证令牌
DEFAULT_AUTH_TOKEN="pFD4yiG0PO41BIGG6dDU"

# 代理类型列表
PROXY_TYPES=(
    "TCP: 提供纯粹的 TCP 端口映射，使服务端能够根据不同的端口将请求路由到不同的内网服务。"
    "UDP: 提供纯粹的 UDP 端口映射，与 TCP 代理类似，但用于 UDP 流量。"
    "HTTP: 专为 HTTP 应用设计，支持修改 Host Header 和增加鉴权等额外功能。"
    "HTTPS: 类似于 HTTP 代理，但专门用于处理 HTTPS 流量。"
    "STCP: 提供安全的 TCP 内网代理，要求在被访问者和访问者的机器上都部署 frpc，不需要在服务端暴露端口。"
    "SUDP: 提供安全的 UDP 内网代理，与 STCP 类似，需要在被访问者和访问者的机器上都部署 frpc，不需要在服务端暴露端口。"
    "XTCP: 点对点内网穿透代理，与 STCP 类似，但流量不需要经过服务器中转。"
    "TCPMUX: 支持服务端 TCP 端口的多路复用，允许通过同一端口访问不同的内网服务。"
)

# --- 颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- 全局状态变量 ---
IS_FRP_INSTALLED=false
DETECTED_FRP_VERSION=""
FRP_SERVICE_FRPS_ENABLED=false
FRP_SERVICE_FRPC_ENABLED=false
DETECTED_FRPC_SERVER_ADDR="" # 新增：用于存储 frpc 配置的服务端地址

# --- 函数定义 ---

log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要以 root 用户权限运行。请使用 sudo 运行。"
        exit 1
    fi
}

check_os() {
    if ! grep -qi "ubuntu" /etc/os-release; then
        log_error "此脚本仅支持 Ubuntu 操作系统。"
        exit 1
    fi
    log_info "操作系统检查通过：Ubuntu。"
}

check_dependencies() {
    for cmd in wget tar systemctl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd 命令未找到。请安装它：sudo apt update && sudo apt install -y $cmd"
            exit 1
        fi
    done
    log_info "依赖检查通过。"
}

get_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64")
            echo "amd64"
            ;;
        "aarch64")
            echo "arm64" # 对应 frp_xxx_linux_arm64.tar.gz
            ;;
        "armv7l" | "armv6l")
            echo "armv7" # 对应 frp_xxx_linux_arm.tar.gz
            ;;
        *)
            log_error "不支持的 CPU 架构: $ARCH"
            exit 1
            ;;
    esac
}

# 获取 FRP 二进制文件的版本号
get_binary_version() {
    local frp_version=""
    # 尝试从 /etc/frp/frps 获取版本
    if [ -f "${INSTALL_DIR}/frps" ]; then
        frp_version=$("${INSTALL_DIR}/frps" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    # 如果 frps 没有，尝试从 /etc/frp/frpc 获取
    if [ -z "$frp_version" ] && [ -f "${INSTALL_DIR}/frpc" ]; then
        frp_version=$("${INSTALL_DIR}/frpc" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    echo "$frp_version"
}

# 检测 FRP 安装状态和版本
detect_frp_status() {
    local frp_version_from_binaries=$(get_binary_version) # 调用函数获取版本

    # 重置全局状态变量
    IS_FRP_INSTALLED=false
    DETECTED_FRP_VERSION=""
    FRP_SERVICE_FRPS_ENABLED=false
    FRP_SERVICE_FRPC_ENABLED=false
    DETECTED_FRPC_SERVER_ADDR="" # 每次检测前重置

    local frps_service_status="disabled"
    local frpc_service_status="disabled"
    local frps_active_status="inactive"
    local frpc_active_status="inactive"

    # 检查 frps 服务文件是否存在且已启用
    if [ -f "${SYSTEMD_DIR}/frps.service" ]; then
        if systemctl is-enabled --quiet frps 2>/dev/null; then
            FRP_SERVICE_FRPS_ENABLED=true
            frps_service_status="enabled"
        fi
        if systemctl is-active --quiet frps 2>/dev/null; then
            frps_active_status="active"
        fi
    fi

    # 检查 frpc 服务文件是否存在且已启用
    if [ -f "${SYSTEMD_DIR}/frpc.service" ]; then
        if systemctl is-enabled --quiet frpc 2>/dev/null; then
            FRP_SERVICE_FRPC_ENABLED=true
            frpc_service_status="enabled"
        fi
        if systemctl is-active --quiet frpc 2>/dev/null; then
            frpc_active_status="active"
            # 如果 frpc 正在运行，尝试从配置文件中获取服务端地址
            local frpc_config_file="${CONFIG_DIR}/frpc.toml"
            if [ -f "$frpc_config_file" ]; then
                # 从 frpc.toml 中提取 serverAddr (例如: serverAddr = "8.8.8.8")
                DETECTED_FRPC_SERVER_ADDR=$(grep -E '^serverAddr\s*=' "$frpc_config_file" | awk -F'=' '{print $2}' | tr -d '[:space:]"' | head -n 1)
            fi
        fi
    fi

    # 根据检测到的状态设置 DETECTED_FRP_VERSION
    if [ "$FRP_SERVICE_FRPS_ENABLED" = true ]; then
        DETECTED_FRP_VERSION="frps (v${frp_version_from_binaries})"
    elif [ "$FRP_SERVICE_FRPC_ENABLED" = true ]; then
        DETECTED_FRP_VERSION="frpc (v${frp_version_from_binaries})"
    elif [ -n "$frp_version_from_binaries" ]; then
        DETECTED_FRP_VERSION="FRP binaries (v${frp_version_from_binaries})" # 仅二进制文件存在
    fi

    if [ -n "$DETECTED_FRP_VERSION" ]; then
        IS_FRP_INSTALLED=true
        log_info "检测到 FRP 已安装: ${DETECTED_FRP_VERSION}"
        echo -e "${YELLOW}当前运行状态：${NC}"
        
        local displayed_service_status=false

        # 如果 frps 服务已启用，显示其状态
        if [ "$FRP_SERVICE_FRPS_ENABLED" = true ]; then
            log_info "frps 服务状态: ${frps_service_status} / ${frps_active_status}."
            displayed_service_status=true
        fi
        
        # 如果 frpc 服务已启用，显示其状态
        if [ "$FRP_SERVICE_FRPC_ENABLED" = true ]; then
            log_info "frpc 服务状态: ${frpc_service_status} / ${frpc_active_status}."
            if [ "$frpc_active_status" = "active" ]; then
                if [ -n "$DETECTED_FRPC_SERVER_ADDR" ]; then
                    # 显示 frpc 配置连接到的服务端地址
                    log_info "frpc 配置连接到服务端: ${DETECTED_FRPC_SERVER_ADDR}"
                else
                    log_warn "frpc 正在运行，但无法从配置文件中获取服务端地址。"
                fi
            fi
            displayed_service_status=true
        fi
        
        # 如果没有任何服务被启用，但二进制文件存在，则显示通用提示
        if [ "$displayed_service_status" = false ] && [ -n "$frp_version_from_binaries" ]; then
            log_info "FRP 二进制文件已安装，但未配置为自启动服务。"
        fi
    else
        log_info "未检测到 FRP 安装。"
    fi
}

uninstall_frp() {
    log_warn "正在卸载 FRP..."

    # 停止并禁用服务
    if systemctl is-active --quiet frps; then
        log_info "停止 frps 服务..."
        systemctl stop frps
    fi
    if systemctl is-enabled --quiet frps; then
        systemctl disable frps
    fi

    if systemctl is-active --quiet frpc; then
        log_info "停止 frpc 服务..."
        systemctl stop frpc
    fi
    if systemctl is-enabled --quiet frpc; then
        systemctl disable frpc
    fi

    # 删除服务文件
    if [ -f "${SYSTEMD_DIR}/frps.service" ]; then
        log_info "删除 frps.service..."
        rm -f "${SYSTEMD_DIR}/frps.service"
    fi
    if [ -f "${SYSTEMD_DIR}/frpc.service" ]; then
        log_info "删除 frpc.service..."
        rm -f "${SYSTEMD_DIR}/frpc.service"
    fi
    systemctl daemon-reload

    # 删除可执行文件和配置文件目录
    if [ -d "${INSTALL_DIR}" ]; then # 现在 INSTALL_DIR 也是 CONFIG_DIR
        log_info "删除 FRP 安装和配置文件目录: ${INSTALL_DIR}..."
        rm -rf "${INSTALL_DIR}"
    fi
    
    # 删除日志目录
    if [ -d "${LOG_DIR}" ]; then
        log_info "删除 FRP 日志目录: ${LOG_DIR}..."
        rm -rf "${LOG_DIR}"
    fi

    log_info "FRP 卸载完成。"
    # 卸载后重置状态，以便 main_menu 重新检测
    DETECTED_FRP_VERSION=""
    IS_FRP_INSTALLED=false
    FRP_SERVICE_FRPS_ENABLED=false
    FRP_SERVICE_FRPC_ENABLED=false
    DETECTED_FRPC_SERVER_ADDR="" # 卸载后重置
}

install_frp_binaries() {
    # This function is now called after a potential uninstall, so IS_FRP_INSTALLED should be false.
    if [ "$IS_FRP_INSTALLED" = true ]; then
        log_error "内部错误：FRP 已安装，但尝试执行全新安装。请先卸载。"
        return 1
    fi

    log_info "正在下载 FRP v${FRP_VERSION}..."
    ARCH_TYPE=$(get_arch)
    DOWNLOAD_URL=""

    if [ "$ARCH_TYPE" == "amd64" ]; then
        DOWNLOAD_URL="$FRP_DOWNLOAD_URL_AMD64"
    elif [ "$ARCH_TYPE" == "arm64" ]; then # 使用 arm64 专用 URL
        DOWNLOAD_URL="$FRP_DOWNLOAD_URL_ARM64"
    elif [ "$ARCH_TYPE" == "armv7" ]; then # 使用 armv7 专用 URL
        DOWNLOAD_URL="$FRP_DOWNLOAD_URL_ARMV7"
    else
        log_error "不支持的 CPU 架构: $ARCH_TYPE"
        return 1
    fi

    TEMP_TAR_FILE="/tmp/frp_${FRP_VERSION}_linux_${ARCH_TYPE}.tar.gz"
    TEMP_DIR="/tmp/frp_install_temp"

    wget -q --show-progress "$DOWNLOAD_URL" -O "$TEMP_TAR_FILE"
    if [ $? -ne 0 ]; then
        log_error "下载 FRP 失败。请检查网络连接或 URL。"
        return 1
    fi
    log_info "FRP 下载完成。"

    mkdir -p "$TEMP_DIR"
    tar -xzf "$TEMP_TAR_FILE" -C "$TEMP_DIR" --strip-components=1
    if [ $? -ne 0 ]; then
        log_error "解压 FRP 文件失败。"
        rm -rf "$TEMP_DIR" "$TEMP_TAR_FILE"
        return 1
    fi
    log_info "FRP 解压完成。"

    log_info "正在安装 FRP 可执行文件到 ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}" # 确保目标目录存在
    mv "${TEMP_DIR}/frps" "${INSTALL_DIR}/frps"
    mv "${TEMP_DIR}/frpc" "${INSTALL_DIR}/frpc"
    
    # 关键修复：强制设置二进制文件所有权为 root:root
    chown root:root "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
    chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc"
    
    sync # 确保文件系统同步
    sleep 0.1 # 增加一个微小延迟，确保文件系统同步
    if [ $? -ne 0 ]; then
        log_error "移动或设置权限失败。"
        rm -rf "$TEMP_DIR" "$TEMP_TAR_FILE"
        return 1
    fi
    log_info "FRP 可执行文件安装成功并设置了正确的权限。"

    log_info "清理下载文件和临时目录..."
    rm -rf "$TEMP_DIR" "$TEMP_TAR_FILE"
    log_info "清理完成。"

    log_info "创建日志目录 ${LOG_DIR}..."
    mkdir -p "${LOG_DIR}"
    # 当以 root 运行服务时，日志目录默认由 root 拥有即可
    chown root:root "${LOG_DIR}"
    chmod 755 "${LOG_DIR}" # root can read/write/execute, others can read/execute
    log_info "日志目录创建并设置权限完成。"
    
    systemctl daemon-reload # 重新加载 systemd 配置
    return 0
}

create_systemd_service() {
    local service_name=$1
    local exec_path=$2 # 完整的二进制文件路径，例如 /etc/frp/frps
    local config_path=$3 # 完整的配置文件路径，例如 /etc/frp/frps.toml

    log_info "创建 ${service_name}.service 系统服务文件..."
    log_warn "!!! 警告: 服务将以 ROOT 用户和 ROOT 组运行，存在安全风险 !!!"
    cat <<EOF > "${SYSTEMD_DIR}/${service_name}.service"
[Unit]
Description=FRP ${service_name} Service
After=network.target

[Service]
Type=simple
User=root
Group=root
Restart=on-failure
RestartSec=1
StartLimitIntervalSec=0
ExecStart=${exec_path} -c ${config_path}
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
    sync # 确保服务文件立即写入磁盘
    systemctl daemon-reload
    systemctl enable "${service_name}"
    log_info "${service_name}.service 创建并启用成功。"
}

configure_frps() {
    if [ ! -f "${INSTALL_DIR}/frps" ]; then
        log_error "frps 可执行文件未找到。请先安装 FRP 二进制文件。"
        return 1
    fi

    log_info "开始配置 FRP 服务端 (frps)..."
    local frps_config_file="${CONFIG_DIR}/frps.toml"

    read -p "请输入 FRP 服务端监听端口 (默认 7000): " BIND_PORT
    BIND_PORT=${BIND_PORT:-7000} # 如果用户未输入，则使用默认值

    log_info "认证令牌将使用默认值: ${DEFAULT_AUTH_TOKEN}"

    cat <<EOF > "${frps_config_file}"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${DEFAULT_AUTH_TOKEN}"
log.to = "${LOG_DIR}/frps.log"
log.level = "info"
log.maxDays = 3
EOF
    sync # 确保配置文件立即写入磁盘
    log_info "frps.toml 配置文件已生成。"
    log_info "实际监听端口: ${BIND_PORT}"
    log_info "认证令牌: ${DEFAULT_AUTH_TOKEN}"

    create_systemd_service "frps" "${INSTALL_DIR}/frps" "${frps_config_file}"

    log_info "FRP 服务端配置完成。尝试启动服务..."
    systemctl stop frps 2>/dev/null # 尝试停止服务，忽略错误
    systemctl reset-failed frps # 清除任何旧的失败状态
    systemctl start frps
    sleep 2 # 等待服务启动
    if systemctl is-active --quiet frps; then
        log_info "frps 服务启动成功。"
        log_info "服务状态简要信息:"
        systemctl status frps --no-pager | head -n 5
    else
        log_error "frps 服务启动失败。请检查日志 (journalctl -u frps)."
        systemctl status frps --no-pager | head -n 5 # 显示失败时的状态
    fi
    log_info "请确保您的防火墙已放行 ${BIND_PORT} 端口。"
    return 0
}

configure_frpc() {
    if [ ! -f "${INSTALL_DIR}/frpc" ]; then
        log_error "frpc 可执行文件未找到。请先安装 FRP 二进制文件。"
        return 1
    fi

    log_info "开始配置 FRP 客户端 (frpc)..."
    local frpc_config_file="${CONFIG_DIR}/frpc.toml"
    local frpc_confd_dir="${CONFIG_DIR}/conf.d"

    read -p "请输入 FRP 服务端 (frps) 的公网 IP 地址: " SERVER_IP
    while [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; do
        log_warn "无效的 IP 地址格式。请重新输入。"
        read -p "请输入 FRP 服务端 (frps) 的公网 IP 地址: " SERVER_IP
    done

    read -p "请输入 FRP 服务端 (frps) 的通信端口 (默认 7000): " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000} # 如果用户未输入，则使用默认值

    log_info "认证令牌将使用默认值: ${DEFAULT_AUTH_TOKEN}"

    cat <<EOF > "${frpc_config_file}"
serverAddr = "${SERVER_IP}"
serverPort = ${SERVER_PORT}
auth.method = "token"
auth.token = "${DEFAULT_AUTH_TOKEN}"
log.to = "${LOG_DIR}/frpc.log"
log.level = "info"
log.maxDays = 3
includes = ["./conf.d/*.toml"]
EOF
    sync # 确保配置文件立即写入磁盘
    log_info "frpc.toml 配置文件已生成。"
    log_info "服务端地址: ${SERVER_IP}:${SERVER_PORT}"
    log_info "认证令牌: ${DEFAULT_AUTH_TOKEN}"

    mkdir -p "${frpc_confd_dir}"
    log_info "已创建代理配置目录: ${frpc_confd_dir}"

    while true; do
        log_info "--- 添加新的代理配置 ---"
        read -p "请输入代理的名称 (例如: ssh_access, web_server): " PROXY_NAME
        if [[ -z "$PROXY_NAME" ]]; then
            log_warn "代理名称不能为空，请重新输入。"
            continue
        fi

        echo "请选择代理类型:"
        for i in "${!PROXY_TYPES[@]}"; do
            echo "  $((i+1)). ${PROXY_TYPES[$i]}"
        done
        read -p "请输入代理类型的序号 (1-${#PROXY_TYPES[@]}): " TYPE_CHOICE

        PROXY_TYPE_STR=""
        case "$TYPE_CHOICE" in
            1) PROXY_TYPE_STR="tcp" ;;
            2) PROXY_TYPE_STR="udp" ;;
            3) PROXY_TYPE_STR="http" ;;
            4) PROXY_TYPE_STR="https" ;;
            5) PROXY_TYPE_STR="stcp" ;;
            6) PROXY_TYPE_STR="sudp" ;;
            7) PROXY_TYPE_STR="xtcp" ;;
            8) PROXY_TYPE_STR="tcpmux" ;;
            *) log_warn "无效的类型选择，请重新输入。" continue ;;
        esac

        read -p "请输入内网服务监听的 IP 地址 (默认 0.0.0.0): " LOCAL_IP_INPUT
        LOCAL_IP=${LOCAL_IP_INPUT:-0.0.0.0} # 如果用户未输入，则使用默认值 0.0.0.0

        read -p "请输入内网服务监听的端口 (例如: 22 for SSH, 80 for HTTP): " LOCAL_PORT
        while ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || ((LOCAL_PORT < 1 || LOCAL_PORT > 65535)); do
            log_warn "无效的端口号。请输入 1 到 65535 之间的数字。"
            read -p "请输入内网服务监听的端口: " LOCAL_PORT
        done

        PROXY_CONFIG_CONTENT="[[proxies]]\nname = \"${PROXY_NAME}\"\ntype = \"${PROXY_TYPE_STR}\"\nlocalIP = \"${LOCAL_IP}\"\nlocalPort = ${LOCAL_PORT}\n"

        case "$PROXY_TYPE_STR" in
            "tcp" | "udp" | "stcp" | "sudp" | "xtcp" | "tcpmux")
                read -p "请输入需要在公网服务器上监听的端口 (例如: 6000 for SSH): " REMOTE_PORT
                while ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || ((REMOTE_PORT < 1 || REMOTE_PORT > 65535)); do
                    log_warn "无效的端口号。请输入 1 到 65535 之间的数字。"
                    read -p "请输入需要在公网服务器上监听的端口: " REMOTE_PORT
                done
                PROXY_CONFIG_CONTENT+="remotePort = ${REMOTE_PORT}\n"
                ;;
            "http" | "https")
                read -p "请输入自定义域名 (例如: myblog.example.com): " CUSTOM_DOMAIN
                if [[ -z "$CUSTOM_DOMAIN" ]]; then
                    log_warn "自定义域名不能为空。"
                    continue
                fi
                PROXY_CONFIG_CONTENT+="customDomains = [\"${CUSTOM_DOMAIN}\"]\n"
                ;;
        esac

        echo -e "${PROXY_CONFIG_CONTENT}" > "${frpc_confd_dir}/${PROXY_NAME}.toml"
        sync # 确保代理配置文件立即写入磁盘
        log_info "代理 ${PROXY_NAME} 配置已保存到 ${frpc_confd_dir}/${PROXY_NAME}.toml"

        read -p "是否继续添加更多代理？(y/N): " ADD_MORE_INPUT # 默认 N
        ADD_MORE=${ADD_MORE_INPUT:-N} 
        if [[ "$ADD_MORE" != "y" && "$ADD_MORE" != "Y" ]]; then
            break
        fi
    done

    create_systemd_service "frpc" "${INSTALL_DIR}/frpc" "${frpc_config_file}"

    log_info "FRP 客户端配置完成。尝试启动服务..."
    systemctl stop frpc 2>/dev/null # 尝试停止服务，忽略错误
    systemctl reset-failed frpc # 清除任何旧的失败状态
    systemctl start frpc
    sleep 2 # 等待服务启动
    if systemctl is-active --quiet frpc; then
        log_info "frpc 服务启动成功。"
        log_info "服务状态简要信息:"
        systemctl status frpc --no-pager | head -n 5
    else
        log_error "frpc 服务启动失败。请检查日志 (journalctl -u frpc)."
        systemctl status frpc --no-pager | head -n 5 # 显示失败时的状态
    fi
    return 0
}

# 新增重启服务函数
restart_frp_service() {
    local service_to_restart=""

    # 优先检查哪个服务是 enabled 的
    if systemctl is-enabled --quiet frps 2>/dev/null; then
        service_to_restart="frps"
    elif systemctl is-enabled --quiet frpc 2>/dev/null; then
        service_to_restart="frpc"
    fi

    if [ -n "$service_to_restart" ]; then
        log_info "正在重启 ${service_to_restart} 服务..."
        systemctl stop "${service_to_restart}" 2>/dev/null # 尝试停止服务，忽略错误
        systemctl reset-failed "${service_to_restart}" # 清除任何旧的失败状态
        systemctl restart "${service_to_restart}"
        sleep 2 # 等待服务重启
        if systemctl is-active --quiet "${service_to_restart}"; then
            log_info "${service_to_restart} 服务重启成功。"
            log_info "服务状态简要信息:"
            systemctl status "${service_to_restart}" --no-pager | head -n 5
        else
            log_error "${service_to_restart} 服务重启失败。请检查日志 (journalctl -u ${service_to_restart})."
            systemctl status "${service_to_restart}" --no-pager | head -n 5 # 显示失败时的状态
        fi
    else
        log_warn "没有检测到已启用或正在运行的 FRP 服务 (frps 或 frpc)。"
    fi
}


# --- 主菜单函数 ---
main_menu() {
    echo ""
    log_info "--- FRP 安装与配置脚本 ---"
    detect_frp_status # 每次显示菜单前更新状态

    echo ""
    echo "请选择操作:"
    echo "  1. 安装/重新安装 FRP 二进制文件 (并可选择立即配置)"
    if [ "$IS_FRP_INSTALLED" = true ]; then
        echo "  2. 配置 FRP (已安装 ${DETECTED_FRP_VERSION})"
    else
        echo "  2. 配置 FRP (请先安装二进制文件)"
    fi
    echo "  3. 卸载 FRP"
    echo "  4. 重启 FRP 服务"
    echo "  5. 退出脚本"
    read -p "请输入您的选择 (1/2/3/4/5): " CHOICE
    echo ""

    case "$CHOICE" in
        1)
            if [ "$IS_FRP_INSTALLED" = true ]; then
                log_warn "FRP 已安装 (${DETECTED_FRP_VERSION})。选择此选项将先卸载旧版本，然后重新安装。"
                read -p "确定要卸载并重新安装吗？(y/n): " CONFIRM_REINSTALL
                if [[ "$CONFIRM_REINSTALL" == "y" || "$CONFIRM_REINSTALL" == "Y" ]]; then
                    uninstall_frp # 执行卸载
                    # 卸载后 IS_FRP_INSTALLED 会被重置为 false
                    install_frp_binaries # 然后安装二进制文件
                    if [ $? -eq 0 ]; then
                        log_info "FRP 二进制文件重新安装成功。"
                        read -p "是否立即配置 FRP 服务？(y/N): " CONFIGURE_NOW_INPUT # 立即提示配置
                        CONFIGURE_NOW=${CONFIGURE_NOW_INPUT:-N}
                        if [[ "$CONFIGURE_NOW" == "y" || "$CONFIGURE_NOW" == "Y" ]]; then
                            detect_frp_status # 重新检测状态，确保二进制文件被识别
                            if [ "$IS_FRP_INSTALLED" = true ]; then
                                # 智能判断配置角色：如果某个服务已启用，则直接进入其配置流程
                                if [ "$FRP_SERVICE_FRPS_ENABLED" = true ]; then
                                    log_info "检测到 frps 服务已启用。将配置 FRP 服务端。"
                                    configure_frps
                                elif [ "$FRP_SERVICE_FRPC_ENABLED" = true ]; then
                                    log_info "检测到 frpc 服务已启用。将配置 FRP 客户端。"
                                    configure_frpc
                                else
                                    # 都没有启用，让用户选择
                                    echo "请选择您要配置的角色:"
                                    echo "  1. FRP 服务端 (frps)"
                                    echo "  2. FRP 客户端 (frpc)"
                                    read -p "请输入您的选择 (1/2): " ROLE_CHOICE
                                    case "$ROLE_CHOICE" in
                                        1) configure_frps ;;
                                        2) configure_frpc ;;
                                        *) log_error "无效的选择，返回主菜单。" ;;
                                    esac
                                fi
                            else
                                log_error "FRP 二进制文件安装后未被正确检测到，无法配置。请检查安装过程。"
                            fi
                        else
                            log_info "取消立即配置。您可以在主菜单选择 '2. 配置 FRP' 进行配置。"
                        fi
                    else
                        log_error "FRP 二进制文件重新安装失败。"
                    fi
                else
                    log_info "取消重新安装。"
                fi
            else # FRP 未安装，直接进行全新安装
                install_frp_binaries
                if [ $? -eq 0 ]; then
                    log_info "FRP 二进制文件安装成功。"
                    read -p "是否立即配置 FRP 服务？(y/N): " CONFIGURE_NOW_INPUT # 立即提示配置
                    CONFIGURE_NOW=${CONFIGURE_NOW_INPUT:-N}
                    if [[ "$CONFIGURE_NOW" == "y" || "$CONFIGURE_NOW" == "Y" ]]; then
                        detect_frp_status # 重新检测状态
                        if [ "$IS_FRP_INSTALLED" = true ]; then
                            # 此时没有服务被启用，所以总是让用户选择角色
                            echo "请选择您要配置的角色:"
                            echo "  1. FRP 服务端 (frps)"
                            echo "  2. FRP 客户端 (frpc)"
                            read -p "请输入您的选择 (1/2): " ROLE_CHOICE
                            case "$ROLE_CHOICE" in
                                1) configure_frps ;;
                                2) configure_frpc ;;
                                *) log_error "无效的选择，返回主菜单。" ;;
                            esac
                        else
                            log_error "FRP 二进制文件安装后未被正确检测到，无法配置。请检查安装过程。"
                        fi
                    else
                        log_info "取消立即配置。您可以在主菜单选择 '2. 配置 FRP' 进行配置。"
                    fi
                else
                    log_error "FRP 二进制文件安装失败。"
                fi
            fi
            ;;
        2)
            if [ "$IS_FRP_INSTALLED" = false ]; then
                log_error "FRP 二进制文件未安装，无法进行配置。请先选择 '1. 安装/重新安装 FRP 二进制文件'。"
            else
                # 智能判断配置角色：如果某个服务已启用，则直接进入其配置流程
                if [ "$FRP_SERVICE_FRPS_ENABLED" = true ]; then
                    log_info "检测到 frps 服务已启用。将配置 FRP 服务端。"
                    configure_frps
                elif [ "$FRP_SERVICE_FRPC_ENABLED" = true ]; then
                    log_info "检测到 frpc 服务已启用。将配置 FRP 客户端。"
                    configure_frpc
                else
                    # 都没有启用，让用户选择
                    echo "请选择您要配置的角色:"
                    echo "  1. FRP 服务端 (frps)"
                    echo "  2. FRP 客户端 (frpc)"
                    read -p "请输入您的选择 (1/2): " ROLE_CHOICE
                    case "$ROLE_CHOICE" in
                        1) configure_frps ;;
                        2) configure_frpc ;;
                        *) log_error "无效的选择，返回主菜单。" ;;
                    esac
                fi
            fi
            ;;
        3)
            uninstall_frp
            ;;
        4) # 新增重启选项的处理
            restart_frp_service
            ;;
        5)
            log_info "退出脚本。"
            exit 0
            ;;
        *)
            log_error "无效的选择，请重新输入。"
            ;;
    esac
}

# --- 主脚本逻辑 ---

check_root
check_os
check_dependencies

while true; do
    main_menu
    echo ""
    read -p "按任意键返回主菜单..." -n 1 -r
    echo ""
done
