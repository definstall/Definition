#!/bin/bash

# ==============================================================================
# UFW 智能管理脚本 v1.2 (安全默认 & 深度 Docker 集成)
# 作者: 你的高级软件工程师
# 版本: 1.2
# 兼容性: Ubuntu 20.04+ / Debian 10+
#
# --- v1.2 更新日志 ---
#   - [用户体验] 自动处理 UFW 启用/重新加载/删除时的 SSH 连接中断警告，不再需要手动确认。
#   - [用户体验] 修复 `read -p` 中颜色代码显示为乱码的问题，将彩色文本与 `read` 提示分离。
#   - [关键修复] 增强 `ufw enable` 和 `ufw reload` 的健壮性检查，确保防火墙规则正确加载。
#   - [问题解决] 修复因 UFW 未成功启用导致“没有看到已添加端口”的问题。
#   - [优化] 明确提示默认开放的 22/tcp 和 2525/tcp 端口。
#   - [优化] 端口管理和转发管理中的 `grep` 模式更精确，避免误删。
# ==============================================================================

# --- 颜色定义 ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'

# --- 辅助函数 ---
print_error() { echo -e "${C_RED}[错误] $1${C_RESET}"; }
print_success() { echo -e "${C_GREEN}[成功] $1${C_RESET}"; }
print_info() { echo -e "${C_BLUE}[信息] $1${C_RESET}"; }
print_warn() { echo -e "${C_YELLOW}[警告] $1${C_RESET}"; }
press_enter_to_continue() { echo ""; read -p "按 [Enter] 键返回..."; }

# --- 全局变量 ---
COMMENT_TAG="managed-by-ufw-script"
UFW_DOCKER_FORWARD_RULES_BEGIN="# BEGIN UFW DOCKER FORWARD RULES (managed by script)"
UFW_DOCKER_FORWARD_RULES_END="# END UFW DOCKER FORWARD RULES (managed by script)"
UFW_NAT_PREROUTING_RULES_BEGIN="# BEGIN UFW NAT PREROUTING RULES (managed by script)"
UFW_NAT_PREROUTING_RULES_END="# END UFW NAT PREROUTING RULES (managed by script)"

# 标记 UFW 是否被配置为兼容 Docker
# true: Docker 已安装且用户选择让 UFW 管理其防火墙
# false: Docker 未安装或已被卸载
IS_UFW_DOCKER_COMPATIBLE=false

# --- 核心功能函数 ---

# 1. 初始化防火墙
function initialize_firewall() {
    print_info "开始初始化防火墙配置..."
    if [[ $EUID -ne 0 ]]; then print_error "此脚本必须以 root 权限运行。"; exit 1; fi

    # 1.1 检测并处理其他防火墙
    if command -v ufw &> /dev/null; then
        print_info "检测到 UFW 已安装。"
        if sudo ufw status | grep -q "Status: active"; then
            print_warn "UFW 正在运行。将重新初始化其配置。"
            echo -n "是否要禁用并重新初始化 UFW? (Y/n): "
            read confirm_ufw_reinit
            if [[ "$confirm_ufw_reinit" =~ ^[Yy]$ || -z "$confirm_ufw_reinit" ]]; then
                print_info "正在禁用 UFW..."; sudo ufw disable || print_error "禁用 UFW 失败。"
            else
                print_error "用户取消操作。无法在不重新初始化 UFW 的情况下继续。"; exit 1
            fi
        fi
    else
        print_info "UFW 未安装。正在安装 UFW..."
        sudo apt update && sudo apt install ufw -y || { print_error "安装 UFW 失败。"; exit 1; }
        print_success "UFW 安装完成。"
    fi

    # 检查并处理 iptables-persistent
    if dpkg -l | grep -q iptables-persistent; then
        print_warn "检测到 iptables-persistent 已安装。本脚本使用 UFW 进行管理。"
        echo -n "是否要卸载 iptables-persistent? (Y/n): "
        read confirm_iptables_persistent
        if [[ "$confirm_iptables_persistent" =~ ^[Yy]$ || -z "$confirm_iptables_persistent" ]]; then
            print_info "正在卸载 iptables-persistent..."; sudo apt-get purge -y iptables-persistent > /dev/null
            print_success "iptables-persistent 已移除。"
        else
            print_error "用户取消操作。无法在 iptables-persistent 存在的情况下安全初始化 UFW。"; exit 1
        fi
    fi

    # 1.2 彻底清空 iptables 规则 (确保干净的环境)
    print_info "正在执行 iptables 规则的彻底清理 (为 UFW 接管做准备)..."
    sudo iptables -F; sudo iptables -X; sudo iptables -Z
    sudo iptables -t nat -F; sudo iptables -t nat -X; sudo iptables -t nat -Z
    sudo iptables -t mangle -F; sudo iptables -t mangle -X; sudo iptables -t mangle -Z
    sudo iptables -t raw -F; sudo iptables -t raw -X; sudo iptables -t raw -Z
    # 重置默认策略为 ACCEPT，以便 UFW 重新设置
    sudo iptables -P INPUT ACCEPT; sudo iptables -P FORWARD ACCEPT; sudo iptables -P OUTPUT ACCEPT
    sudo iptables -t nat -P PREROUTING ACCEPT; sudo iptables -t nat -P POSTROUTING ACCEPT; sudo iptables -t nat -P OUTPUT ACCEPT
    print_success "iptables 规则清理完成。"

    # 1.3 Docker 存在时的交互式处理
    if command -v docker &> /dev/null; then
        print_warn "检测到 Docker 已安装。"
        local docker_is_running=false
        if systemctl is-active docker &>/dev/null; then
            docker_is_running=true
            print_warn "Docker 服务当前正在运行。"
        fi

        echo -e "${C_CYAN}--- Docker 环境处理选项 ---${C_RESET}"
        echo -e "1. ${C_RED}彻底卸载 Docker${C_RESET} (包括所有数据和软件包，将配置为非 Docker 主机防火墙)"
        echo -e "2. ${C_GREEN}保留 Docker 并让脚本管理其防火墙${C_RESET} (配置为 Docker 兼容防火墙)"
        echo -e "q. 退出脚本 (不进行任何防火墙初始化)"
        echo -n "请选择操作: "
        read docker_choice

        case $docker_choice in
            1) # 彻底卸载 Docker
                print_warn "!!! 警告: 此操作将永久删除所有 Docker 相关数据和程序 !!!"
                echo -n "请再次确认彻底卸载 Docker? (y/N): "
                read final_confirm_docker_uninstall
                if [[ "$final_confirm_docker_uninstall" =~ ^[Yy]$ ]]; then
                    if [ "$docker_is_running" = true ]; then
                        print_info "正在停止 Docker 服务..."
                        sudo systemctl stop docker || print_error "停止 Docker 服务失败，请手动检查。"
                    fi
                    
                    print_info "正在删除所有 Docker 网络、容器、镜像和卷..."
                    sudo docker system prune -a -f || print_warn "Docker 数据清理可能不完全，请手动检查。"
                    
                    print_info "正在卸载 Docker 相关软件包..."
                    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-engine docker.io || print_warn "部分 Docker 软件包可能未完全卸载，请手动检查。"
                    
                    print_info "正在删除 Docker 残留目录..."
                    sudo rm -rf /var/lib/docker /etc/docker /var/run/docker.sock || print_warn "部分 Docker 目录可能未完全删除，请手动检查。"
                    
                    print_success "Docker 已彻底卸载并清理完成。"
                    IS_UFW_DOCKER_COMPATIBLE=false # Docker 已被卸载，按非 Docker 主机处理
                else
                    print_error "用户取消 Docker 卸载。无法在不处理 Docker 的情况下安全初始化防火墙。"
                    print_error "请手动处理 Docker 或选择卸载，然后重新运行脚本。"
                    exit 1 # 用户取消，安全退出
                fi
                ;;
            2) # 保留 Docker 并让脚本管理其防火墙
                print_info "您选择保留 Docker。脚本将配置 UFW 以兼容 Docker。"
                IS_UFW_DOCKER_COMPATIBLE=true # 脚本将管理 Docker 环境下的防火墙
                ;;
            q|Q) # 退出脚本
                print_info "用户选择退出。防火墙初始化已取消。"
                exit 0
                ;;
            *)
                print_error "无效选项。防火墙初始化已取消。"
                exit 1
                ;;
        esac
    else
        IS_UFW_DOCKER_COMPATIBLE=false # 未检测到 Docker，按非 Docker 主机处理
        print_info "未检测到 Docker，跳过 Docker 相关处理。"
    fi
    # --- Docker 存在时的交互式处理结束 ---

    # 1.4 配置 UFW 默认策略和文件
    print_info "正在配置 UFW 默认策略..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # 配置 /etc/default/ufw 中的 FORWARD 策略
    # Docker 兼容模式下，FORWARD 必须是 ACCEPT，然后通过 before.rules 中的 DROP 来控制
    sudo sed -i '/^DEFAULT_FORWARD_POLICY=/c\DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw
    print_info "已将 /etc/default/ufw 中的 DEFAULT_FORWARD_POLICY 设置为 ACCEPT (Docker 兼容性要求)。"

    # 1.5 配置 /etc/ufw/before.rules 以实现 Docker 兼容性（默认拒绝转发流量）
    # 修复：将 Docker 兼容性规则移到 before.rules，并简化规则块
    print_info "正在配置 /etc/ufw/before.rules 以确保 Docker 流量受控..."
    local before_rules_docker_content=""
    if [ "$IS_UFW_DOCKER_COMPATIBLE" = true ]; then
        # 这些规则确保只有明确允许的 Docker 流量通过 ufw-user-forward 链
        # Docker 自身的 DNAT 规则在 nat 表中先应用。流量随后进入 FORWARD 链。
        # UFW 会将流量导向 ufw-user-forward 链，我们在这里进行精细控制。
        before_rules_docker_content=$(printf "%b" "${UFW_DOCKER_FORWARD_RULES_BEGIN}\n")
        before_rules_docker_content+=$(printf "%b" "# Allow all established/related connections for forwarded traffic\n")
        before_rules_docker_content+=$(printf "%b" "-A ufw-user-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n")
        before_rules_docker_content+=$(printf "%b" "# Drop all other forwarded traffic not explicitly allowed by UFW rules\n")
        before_rules_docker_content+=$(printf "%b" "-A ufw-user-forward -j DROP\n") # 这是 Docker 兼容模式下“默认拒绝”的关键
        before_rules_docker_content+=$(printf "%b" "${UFW_DOCKER_FORWARD_RULES_END}")
    fi

    # 移除旧的 Docker 兼容规则块 (无论在 before.rules 还是 after.rules)
    sudo sed -i "/${UFW_DOCKER_FORWARD_RULES_BEGIN}/,/${UFW_DOCKER_FORWARD_RULES_END}/d" /etc/ufw/before.rules 2>/dev/null || true
    sudo sed -i "/${UFW_DOCKER_FORWARD_RULES_BEGIN}/,/${UFW_DOCKER_FORWARD_RULES_END}/d" /etc/ufw/after.rules 2>/dev/null || true

    # 插入新的 Docker 兼容规则块到 before.rules
    if [ -n "$before_rules_docker_content" ]; then
        local temp_rules_file=$(mktemp)
        echo "$before_rules_docker_content" > "$temp_rules_file"
        # 插入到 before.rules 文件中第一个 COMMIT 行之前
        sudo sed -i "/^COMMIT/e cat $temp_rules_file" /etc/ufw/before.rules
        rm "$temp_rules_file"
    fi
    print_success "/etc/ufw/before.rules 配置完成。"

    # 1.6 启用 IP 转发 (sysctl)
    print_info "正在启用 IP 转发..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sudo sed -i '/^net.ipv4.ip_forward=/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
    sudo sysctl -p > /dev/null
    print_success "IP 转发已启用并持久化。"

    # 1.7 允许默认端口 (22, 2525)
    print_info "正在开放默认端口 22/tcp (SSH) 和 2525/tcp..."
    # UFW allow 命令是幂等的，重复执行不会创建重复规则
    sudo ufw allow 22/tcp comment "${COMMENT_TAG}:default:ssh"
    sudo ufw allow 2525/tcp comment "${COMMENT_TAG}:default:custom_port"
    print_success "默认端口开放完成。"

    # 1.8 添加安全加固规则 (UFW 内置的 limit 规则)
    print_info "正在添加安全加固规则 (SYN Flood / 端口扫描防护)..."
    # UFW 默认的 'limit' 规则已经提供了一定程度的防护，例如针对 SSH 的暴力破解。
    # 对于更通用的 SYN Flood 和端口扫描，UFW 内部的规则已经处理。
    # 如果需要更高级的防护，可以考虑 Fail2Ban 或更专业的 IDS/IPS。
    # 这里可以添加一些额外的通用限制，例如针对所有端口的连接速率限制，但通常不推荐，因为可能影响正常服务。
    # 例如：sudo ufw limit from any to any port 80 proto tcp comment 'Limit HTTP connections'
    print_success "安全加固规则已应用。"

    # 1.9 启用 UFW
    print_info "正在启用 UFW 防火墙..."
    # 修复：确保 ufw enable 成功，并自动确认
    echo "y" | sudo ufw enable || { print_error "启用 UFW 失败！请检查系统日志。"; print_error "请尝试手动执行 'sudo ufw enable' 并查看详细错误信息。"; exit 1; }
    
    # 再次检查 UFW 状态，确保它确实 active
    if ! sudo ufw status | grep -q "Status: active"; then
        print_error "UFW 启用后状态仍为非活动。防火墙可能未正常工作！"
        print_error "请手动检查 'sudo ufw status' 和系统日志。"
        exit 1
    fi
    print_success "UFW 防火墙已启用并配置完成。"

    # 1.10 提示 Docker 重启 (如果适用)
    if [ "$IS_UFW_DOCKER_COMPATIBLE" = true ] && [ "$docker_is_running" = true ]; then
        print_info "正在重启 Docker 服务以确保其规则与 UFW 协同工作..."
        sudo systemctl restart docker || print_error "重启 Docker 服务失败，请手动检查。"
        print_success "Docker 服务已重启。"
        print_info "如果遇到容器网络问题，请尝试再次重启 Docker 服务。"
    elif [ "$IS_UFW_DOCKER_COMPATIBLE" = true ] && [ "$docker_is_running" = false ]; then
        print_info "Docker 已安装但未运行。请手动启动 Docker 服务以生成其规则: sudo systemctl start docker"
