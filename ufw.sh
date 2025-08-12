#!/bin/bash

# ==============================================================================
# UFW 智能管理脚本 v5.0 (安全默认 & 无 Docker 兼容 & 手动启用)
# 作者: 你的高级软件工程师 (由 AI 助手优化和整合)
# 版本: 5.0
# 兼容性: Ubuntu 20.04+ / Debian 10+
#
# --- v5.0 更新日志 ---
#   - [关键变更] 移除 `initialize_firewall` 函数中的 UFW 自动启用逻辑：
#     - 脚本初始化时将只配置 UFW 规则，不再强制启用防火墙。
#     - 在初始化完成后，会明确提示用户 UFW 处于禁用状态，并指导手动启用。
#   - [新功能] 在主菜单中添加 "启用 UFW 防火墙" 选项：
#     - 用户可以通过此选项手动激活 UFW，并包含必要的错误检查和提示。
#   - [优化] 保持了 v4.3 中所有关于颜色显示、自动确认、端口管理和端口转发的优化。
#   - [功能移除] 彻底移除了所有 Docker 兼容性相关功能和代码。
# ==============================================================================

# --- 颜色定义 ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'

# --- 辅助函数 ---
print_error() { echo -e "${C_RED}[错误] $1${C_RESET}"; }
print_success() { echo -e "${C_GREEN}[成功] $1${C_RESET}"; }
print_info() { echo -e "${C_BLUE}[信息] $1${C_RESET}"; }
print_warn() { echo -e "${C_YELLOW}[警告] $1${C_RESET}"; }
press_enter_to_continue() { echo ""; read -rp "按 [Enter] 键返回..."; }

# --- 全局变量 ---
COMMENT_TAG="managed-by-ufw-script" # 用于标记由本脚本管理的规则
UFW_NAT_PREROUTING_RULES_BEGIN="# BEGIN UFW NAT PREROUTING RULES (managed by script)"
UFW_NAT_PREROUTING_RULES_END="# END UFW NAT PREROUTING RULES (managed by script)"

# --- 核心功能函数 ---

# 确认操作，默认Y
confirm_action() {
    local prompt_msg="$1"
    echo -e "${C_YELLOW}$prompt_msg (Y/n)${C_RESET}" # 提示默认Y
    read -rp "" choice # 直接读取输入，不带额外提示
    [[ "${choice:-Y}" =~ ^[Yy]$ ]] # 默认Y
}

# 重新加载UFW规则 (优化版)
reload_ufw() {
    print_info "正在重新加载 UFW 规则..."
    # 检查 UFW 是否处于活动状态
    if ! sudo ufw status | grep -q "Status: active"; then
        print_warn "UFW 当前未启用。跳过重新加载。"
        press_enter_to_continue
        return # 如果未启用，则直接返回
    fi

    # 如果 UFW 已启用，则执行重新加载并自动确认
    echo "y" | sudo ufw reload > /dev/null 2>&1 # 抑制 UFW 重新加载的输出
    local reload_exit_code=$?

    if [[ $reload_exit_code -eq 0 ]]; then
        print_success "UFW 规则重新加载成功。"
    else
        print_error "UFW 规则重新加载失败。请检查 UFW 配置或系统日志。"
    fi
    press_enter_to_continue
}

# 新增函数：手动启用 UFW 防火墙
function enable_ufw_firewall() {
    print_info "正在尝试启用 UFW 防火墙..."
    if sudo ufw status | grep -q "Status: active"; then
        print_warn "UFW 已经处于活动状态，无需再次启用。"
        press_enter_to_continue
        return
    fi

    local ufw_enable_output=$(echo "y" | sudo ufw enable 2>&1)
    local ufw_enable_exit_code=$?

    # 给 UFW 一点时间来应用规则并更新其状态
    sleep 2

    if [[ $ufw_enable_exit_code -eq 0 ]] && sudo ufw status | grep -q "Status: active"; then
        print_success "UFW 防火墙已成功启用。"
    else
        print_error "UFW 启用失败！UFW 命令退出码: ${ufw_enable_exit_code}"
        print_error "UFW enable 命令输出 (可能包含警告/错误):"
        echo -e "${C_YELLOW}--- UFW Enable Output Start ---${C_RESET}"
        echo -e "${C_YELLOW}${ufw_enable_output}${C_RESET}"
        echo -e "${C_YELLOW}--- UFW Enable Output End ---${C_RESET}"
        print_error "请务必手动运行以下命令检查 UFW 服务状态和日志："
        print_error "  ${C_YELLOW}sudo systemctl status ufw${C_RESET}"
        print_error "  ${C_YELLOW}journalctl -xeu ufw${C_RESET}"
        print_error "常见问题：IPv6 配置不当可能导致 UFW 启动失败。尝试在 /etc/default/ufw 中设置 IPV6=no 进行测试。"
    fi
    press_enter_to_continue
}


# 1. 初始化防火墙
function initialize_firewall() {
    print_info "开始初始化防火墙配置..."
    if [[ $EUID -ne 0 ]]; then print_error "此脚本必须以 root 权限运行。"; exit 1; fi

    # 1.1 检测并处理其他防火墙
    if command -v ufw &> /dev/null; then
        print_info "检测到 UFW 已安装。"
        if sudo ufw status | grep -q "Status: active"; then
            print_warn "UFW 正在运行。将重新初始化其配置。"
            if confirm_action "是否要禁用并重新初始化 UFW?"; then # 默认Y
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
        if confirm_action "是否要卸载 iptables-persistent?"; then # 默认Y
            print_info "正在卸载 iptables-persistent..."; sudo apt-get purge -y iptables-persistent > /dev/null
            print_success "iptables-persistent 已移除。"
        else
            print_error "用户取消操作。无法在 iptables-persistent 存在的情况下安全初始化 UFW。"; exit 1
        fi
    fi

    # 1.2 移除 iptables 彻底清理步骤 (根据用户反馈，此步骤可能导致卡顿且非必要)
    print_info "跳过 iptables 规则的彻底清理，UFW 将自行管理底层规则。"


    # --- 新增：重置 UFW 到初始状态 ---
    print_info "正在重置 UFW 到初始状态 (这将删除所有现有 UFW 规则)..."
    echo "y" | sudo ufw reset || { print_error "重置 UFW 失败。"; exit 1; }
    print_success "UFW 已重置。"
    # --- 新增结束 ---

    # 1.3 移除 Docker 存在时的交互式处理 (整个块已移除)

    # 1.4 配置 UFW 默认策略和文件
    print_info "正在配置 UFW 默认策略..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # 配置 /etc/default/ufw 中的 FORWARD 策略 (恢复为 DROP，非 Docker 环境的标准安全配置)
    sudo sed -i '/^DEFAULT_FORWARD_POLICY=/c\DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw
    print_info "已将 /etc/default/ufw 中的 DEFAULT_FORWARD_POLICY 设置为 DROP (标准安全配置)。"

    # 1.5 移除 Docker 兼容性规则配置 (整个块已移除)

    # 1.6 启用 IP 转发 (sysctl) - 端口转发功能仍需要
    print_info "正在启用 IP 转发..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sudo sed -i '/^net.ipv4.ip_forward=/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
    sudo sysctl -p > /dev/null
    print_success "IP 转发已启用并持久化。"

    # 1.7 允许默认端口 (22)
    print_info "正在开放默认端口 22/tcp (SSH)..."
    sudo ufw allow 22/tcp comment "${COMMENT_TAG}:default:ssh"
    print_success "默认端口开放完成。"

    # 1.8 添加安全加固规则 (UFW 内置的 limit 规则)
    print_info "正在添加安全加固规则 (SYN Flood / 端口扫描防护)..."
    print_success "安全加固规则已应用。"

    # 1.9 移除自动启用 UFW 逻辑
    print_warn "UFW 防火墙已配置完成，但当前处于 ${C_RED}禁用状态${C_RESET}。"
    print_warn "请在主菜单中选择 '${C_GREEN}7. 启用 UFW 防火墙${C_RESET}' 或手动运行 '${C_YELLOW}sudo ufw enable${C_RESET}' 来激活防火墙。"
    
    print_success "防火墙初始化完成，规则已自动保存。"
    sleep 2
}

# 2. 端口管理
function manage_ports() {
    while true; do
        clear
        echo -e "${C_CYAN}--- 主机端口管理 ---${C_RESET}" # 移除 Docker 状态显示
        echo "1. 添加新端口规则"
        echo "2. 查看已添加的端口规则"
        echo "3. 删除端口规则"
        echo "q. 返回主菜单"
        read -rp "请选择操作: " choice
        case $choice in
            1) add_port_rule ;;
            2) view_port_rules ;;
            3) delete_port_rule ;;
            q|Q) break ;;
            *) print_error "无效选项。" ;;
        esac
    done
}

# 2.1 添加端口规则
function add_port_rule() {
    echo -e "${C_BLUE}--- 添加端口规则 ---${C_RESET}"
    read -rp "请输入端口号或范围 (例如: 80, 22/tcp, 8000:8010): " port_num
    if [[ -z "$port_num" ]]; then
        print_error "端口号不能为空。"
        press_enter_to_continue
        return
    fi

    read -rp "请输入协议 (tcp/udp/both, 默认: both): " protocol
    protocol=${protocol:-both}
    read -rp "请输入允许访问的源IP地址 (留空则为任意IP): " source_ip

    # 添加 COMMENT_TAG 以便后续管理
    local rule_comment="${COMMENT_TAG}:port:${port_num}:${protocol}"
    if [[ -n "$source_ip" ]]; then
        rule_comment+=":from:${source_ip}"
    else
        rule_comment+=":from:any" # 明确标记为any
    fi

    local ufw_cmd="sudo ufw allow"
    if [[ -n "$source_ip" ]]; then
        ufw_cmd+=" from ${source_ip}"
    fi
    ufw_cmd+=" to any port ${port_num}"
    if [[ "$protocol" != "both" ]]; then
        ufw_cmd+=" proto ${protocol}"
    fi
    ufw_cmd+=" comment \"${rule_comment}\""

    print_info "将执行: ${ufw_cmd}"
    if eval ${ufw_cmd}; then
        print_success "端口规则添加成功。"
    else
        print_error "添加端口规则失败。"
    fi
    # 自动重新加载 UFW
    reload_ufw # 调用优化后的 reload_ufw 函数
}

# 2.2 查看端口规则 (显示由脚本管理的规则)
function view_port_rules() {
    print_info "--- 当前由脚本管理的 UFW 规则 (包括 IPv4 和 IPv6) ---"
    # 过滤出带有 COMMENT_TAG 的规则
    sudo ufw status numbered | grep --color=never "${COMMENT_TAG}:"
    press_enter_to_continue
}

# 2.3 删除端口规则
function delete_port_rule() {
    print_info "--- 删除端口规则 ---"
    sudo ufw status numbered # 显示所有规则及其编号
    print_warn "请注意: 删除规则可能导致服务不可用或安全风险。"
    read -rp "请输入要删除的规则编号: " rule_num
    if [[ -z "$rule_num" || ! "$rule_num" =~ ^[0-9]+$ ]]; then
        print_error "无效的规则编号。"
        press_enter_to_continue
        return
    fi

    if confirm_action "确定要删除规则 ${rule_num} 吗？"; then # confirm_action 默认Y
        # 自动确认 ufw delete 操作，并抑制其输出，只检查退出状态
        echo "y" | sudo ufw delete "$rule_num" > /dev/null 2>&1
        local delete_exit_code=$? # 获取 ufw delete 命令的退出状态码

        if [[ $delete_exit_code -eq 0 ]]; then
            print_success "规则 ${rule_num} 已成功删除。"
        else
            print_error "删除规则失败。UFW 命令返回错误码: ${delete_exit_code}";
            print_error "请检查 UFW 状态或规则编号是否正确。"
        fi
    else
        print_info "操作已取消。"; fi
    # 自动重新加载 UFW
    reload_ufw # 调用优化后的 reload_ufw 函数
}


# 3. 端口转发 (NAT) 管理
function manage_forwarding() {
    while true; do
        clear; echo -e "${C_CYAN}--- 端口转发 (NAT) 管理 ---${C_RESET}"
        echo "1. 添加新转发规则"
        echo "2. 查看已添加的转发规则"
        echo "3. 删除转发规则"
        echo "q. 返回主菜单"
        read -rp "请选择操作: " choice
        case $choice in
            1) add_forwarding_rule ;;
            2) view_forwarding_rules ;;
            3) delete_forwarding_rule ;;
            q|Q) break ;;
            *) print_error "无效选项。" ;;
        esac
    done
}

function add_forwarding_rule() {
    read -rp "请输入源端口 (本机被访问的端口): " from_port
    [[ -z "$from_port" ]] && { print_error "源端口不能为空。"; press_enter_to_continue; return; }
    read -rp "请输入目标IP (转发到哪个IP，例如 192.168.1.100): " to_ip
    [[ -z "$to_ip" ]] && { print_error "目标IP不能为空。"; press_enter_to_continue; return; }
    read -rp "请输入目标端口 (转发到哪个端口): " to_port
    [[ -z "$to_port" ]] && { print_error "目标端口不能为空。"; press_enter_to_continue; return; }
    read -rp "请输入协议 (tcp/udp) [默认: tcp]: " proto
    proto=${proto:-tcp}

    local rule_comment="${COMMENT_TAG}:fwd:${from_port}:${proto}:to:${to_ip}:${to_port}"
    local nat_rule="-A PREROUTING -p ${proto} --dport ${from_port} -j DNAT --to-destination ${to_ip}:${to_port} # ${rule_comment}"

    # 检查并删除旧的同类规则
    print_info "正在检查并删除端口转发 ${from_port}/${proto} -> ${to_ip}:${to_port} 的旧规则..."
    sudo sed -i "/^.*${rule_comment}.*$/d" /etc/ufw/before.rules 2>/dev/null || true
    print_success "旧规则清理完成。"

    # 添加规则到 /etc/ufw/before.rules
    print_info "正在添加转发规则到 /etc/ufw/before.rules..."
    # 确保 NAT PREROUTING 规则块的标记存在
    if ! grep -q "${UFW_NAT_PREROUTING_RULES_BEGIN}" /etc/ufw/before.rules; then
        local nat_block_markers=$(printf "%b" "${UFW_NAT_PREROUTING_RULES_BEGIN}\n${UFW_NAT_PREROUTING_RULES_END}")
        local temp_marker_file=$(mktemp)
        echo "$nat_block_markers" > "$temp_marker_file"
        sudo sed -i "/^COMMIT/e cat $temp_marker_file" /etc/ufw/before.rules
        rm "$temp_marker_file"
    fi
    # 在 END 标记之前插入规则
    local temp_rule_file=$(mktemp)
    echo "$nat_rule" > "$temp_rule_file"
    sudo sed -i "/${UFW_NAT_PREROUTING_RULES_END}/e cat $temp_rule_file" /etc/ufw/before.rules
    rm "$temp_rule_file"

    # 重新加载 UFW 使规则生效
    reload_ufw # 调用优化后的 reload_ufw 函数
    print_success "端口转发规则添加成功。"
    print_warn "注意：如果目标IP不是本机，可能需要配置 MASQUERADE (SNAT) 规则，请根据您的网络环境手动添加。"
    press_enter_to_continue
}

function view_forwarding_rules() {
    print_info "--- 当前由脚本管理的转发规则 (来自 /etc/ufw/before.rules) ---"
    grep "${COMMENT_TAG}:fwd:" /etc/ufw/before.rules | sed -E "s/.*(${COMMENT_TAG}:fwd:[^ ]+).*/\1/"
    press_enter_to_continue
}

function delete_forwarding_rule() {
    print_info "--- 删除端口转发规则 ---"
    local managed_rules=()
    local rule_comments=()
    
    while IFS= read -r line; do
        if [[ $line =~ ^.*(${COMMENT_TAG}:fwd:[^\"]+).*$ ]]; then
            local comment_content=${BASH_REMATCH[1]}
            local fwd_info=$(echo "$comment_content" | sed -E 's/.*:fwd:([0-9]+):([^:]+):to:([^:]+):([0-9]+)/\1\/\2 -> \3:\4/')
            managed_rules+=("${fwd_info}")
            rule_comments+=("${comment_content}")
        fi
    done < <(grep "${COMMENT_TAG}:fwd:" /etc/ufw/before.rules)

    if [ ${#managed_rules[@]} -eq 0 ]; then
        print_warn "没有找到由本脚本管理的任何转发规则。"
        press_enter_to_continue
        return
    fi

    managed_rules+=("返回")
    print_info "请选择要删除的转发规则:"
    select choice in "${managed_rules[@]}"; do
        if [[ "$choice" == "返回" ]]; then break; fi
        if [ -n "$choice" ]; then
            local selected_comment=${rule_comments[$((REPLY-1))]}
            print_warn "将要删除转发规则: ${choice}"
            if confirm_action "确认删除吗?"; then # 默认Y
                sudo sed -i "/^.*${selected_comment}.*$/d" /etc/ufw/before.rules
                # 重新加载 UFW 使规则生效
                reload_ufw # 调用优化后的 reload_ufw 函数
                print_success "转发规则已成功删除。"
            else
                print_info "操作已取消。"; fi
        else
            print_error "无效选项。"; fi
        break
    done
    press_enter_to_continue
}

# 4. 负载均衡/轮询功能 (不实现，提供建议)
function manage_load_balancing() {
    clear
    echo -e "${C_CYAN}--- 负载均衡/轮询功能 ---${C_RESET}"
    print_warn "UFW (Uncomplicated Firewall) 主要用于简化主机防火墙管理，不 directly 支持复杂的负载均衡或轮询功能。"
    print_warn "这些功能通常在应用层或更专业的网络设备上实现，例如："
    print_info "  - ${C_GREEN}Nginx${C_RESET}: 强大的反向代理和 HTTP/TCP 负载均衡器。"
    print_info "  - ${C_GREEN}HAProxy${C_RESET}: 高性能的 TCP/HTTP 负载均衡器和代理服务器。"
    print_info "  - ${C_GREEN}LVS (Linux Virtual Server)${C_RESET}: 基于内核的 IP 负载均衡解决方案。"
    print_info "建议您根据具体需求选择并配置上述专业工具来实现负载均衡。"
    press_enter_to_continue
}

# 5. 实时流量监控
function view_traffic() {
    print_info "正在启动实时流量监控... (按 Ctrl+C 退出)"
    sleep 1
    # 检查 iftop 或 nload 是否安装，提供更好的用户体验
    if command -v iftop &> /dev/null; then
        print_info "${C_GREEN}iftop 已安装，正在启动实时流量监控 (按 'q' 退出)...${C_RESET}"
        sudo iftop -P -N -s 2 # -P: show ports, -N: no hostname, -s 2: update every 2 seconds
    elif command -v nload &> /dev/null; then
        print_info "${C_GREEN}nload 已安装，正在启动实时流量监控 (按 'q' 退出)...${C_RESET}"
        sudo nload
    else
        print_error "iftop 或 nload 未安装。建议安装其中一个以查看实时流量。"
        print_warn "您可以尝试安装: sudo apt install iftop 或 sudo apt install nload"
        print_info "以下是当前网络接口统计信息 (非实时):"
        ip -s link
        echo ""
        print_info "以下是当前监听端口和连接 (非实时):"
        ss -tulnp
    fi
    press_enter_to_continue
}

# 6. 卸载功能
function uninstall_firewall() {
    clear
    print_warn "!!! 极度危险操作 !!!"
    print_warn "此操作将执行以下动作:"
    print_warn "1. 禁用 UFW 防火墙。"
    print_warn "2. 将所有 iptables 链的默认策略设置为 ACCEPT，服务器将完全暴露在公网。"
    print_warn "3. 卸载 UFW 软件包。"
    print_warn "4. 删除脚本添加的自定义规则文件内容。"
    echo ""
    read -rp "要继续，请输入 'YES' (大小写敏感): " confirm1
    if [ "$confirm1" != "YES" ]; then print_info "操作已取消。"; press_enter_to_continue; return; fi
    read -rp "请再次输入 'DELETE MY FIREWALL' 以最终确认: " confirm2
    if [ "$confirm2" != "DELETE MY FIREWALL" ]; then print_info "操作已取消。"; press_enter_to_continue; return; fi
    
    print_info "正在禁用 UFW..."
    sudo ufw disable || print_error "禁用 UFW 失败。"
    
    print_info "正在重置 iptables 默认策略为 ACCEPT..."
    sudo iptables -P INPUT ACCEPT; sudo iptables -P FORWARD ACCEPT; sudo iptables -P OUTPUT ACCEPT
    sudo iptables -t nat -P PREROUTING ACCEPT; sudo iptables -t nat -P POSTROUTING ACCEPT; sudo iptables -t nat -P OUTPUT ACCEPT
    sudo iptables -t mangle -P PREROUTING ACCEPT; sudo iptables -t mangle -P INPUT ACCEPT; sudo iptables -t mangle -P FORWARD ACCEPT; sudo iptables -t mangle -P OUTPUT ACCEPT; sudo iptables -t mangle -P POSTROUTING ACCEPT
    sudo iptables -t raw -P PREROUTING ACCEPT; sudo iptables -t raw -P OUTPUT ACCEPT
    print_success "iptables 默认策略已设为 ACCEPT。"

    print_info "正在卸载 UFW 软件包..."
    sudo apt-get purge -y ufw > /dev/null
    print_success "UFW 已卸载。"

    print_info "正在清理脚本添加的自定义规则文件内容..."
    # 清理 before.rules 和 after.rules 中的脚本标记块 (包括旧的 Docker 标记，以防万一)
    sudo sed -i "/# BEGIN UFW DOCKER FORWARD RULES (managed by script)/,/# END UFW DOCKER FORWARD RULES (managed by script)/d" /etc/ufw/before.rules 2>/dev/null || true
    sudo sed -i "/# BEGIN UFW DOCKER FORWARD RULES (managed by script)/,/# END UFW DOCKER FORWARD RULES (managed by script)/d" /etc/ufw/after.rules 2>/dev/null || true
    sudo sed -i "/${UFW_NAT_PREROUTING_RULES_BEGIN}/,/${UFW_NAT_PREROUTING_RULES_END}/d" /etc/ufw/before.rules 2>/dev/null || true
    
    # 恢复 /etc/default/ufw 的默认转发策略
    sudo sed -i '/^DEFAULT_FORWARD_POLICY=/c\DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null || true
    # 禁用 IP 转发
    sudo sysctl -w net.ipv4.ip_forward=0 > /dev/null
    sudo sed -i '/^net.ipv4.ip_forward=/c\net.ipv4.ip_forward=0' /etc/sysctl.conf 2>/dev/null || true
    sudo sysctl -p > /dev/null
    print_success "自定义规则和配置已清理。"

    echo ""; print_warn "防火墙已完全禁用和移除。您的服务器现在不受保护！"
    press_enter_to_continue
}

# --- 主菜单 ---
function main_menu() {
    # 首次运行或 UFW 未安装/未启用时，自动初始化配置
    if ! command -v ufw &> /dev/null || ! sudo ufw status | grep -q "Status: active"; then
        initialize_firewall
    fi

    while true; do
        clear
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e "${C_CYAN}  UFW 智能管理脚本 v5.0 (安全默认 & 无 Docker)      ${C_RESET}"
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        print_info "所有规则变更后将自动保存，无需手动操作。"
        # 显示 UFW 当前状态
        if sudo ufw status | grep -q "Status: active"; then
            echo -e " UFW 状态: ${C_GREEN}已启用${C_RESET}"
        else
            echo -e " UFW 状态: ${C_RED}已禁用${C_RESET}"
        fi
        echo "-----------------------------------------------------"
        echo -e "1. 端口管理 (添加/查看/删除)"
        echo -e "2. 端口转发(NAT)管理 (添加/查看/删除)"
        echo -e "3. 负载均衡/轮询 (说明与建议)"
        echo -e "4. 实时查看网络流量和规则计数"
        echo -e "5. ${C_RED}[危险] 重新运行初始化并应用基础安全配置${C_RESET}"
        echo -e "6. ${C_RED}[极度危险] 卸载并重置防火墙${C_RESET}"
        echo -e "7. ${C_GREEN}启用 UFW 防火墙${C_RESET}" # 新增选项
        echo "q. 退出"
        echo "-----------------------------------------------------"
        read -rp "请输入您的选择: " choice

        case $choice in
            1) manage_ports ;;
            2) manage_forwarding ;;
            3) manage_load_balancing ;;
            4) view_traffic ;;
            5) initialize_firewall; press_enter_to_continue ;;
            6) uninstall_firewall ;;
            7) enable_ufw_firewall ;; # 调用新函数
            q|Q) print_info "正在退出。"; exit 0 ;;
            *) print_error "无效选项，请重试。"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main_menu
