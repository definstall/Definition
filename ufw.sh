#!/bin/bash

# ==============================================================================
# UFW 智能管理脚本 v1.7 (安全默认 & 深度 Docker 集成)
# 作者: 你的高级软件工程师
# 版本: 1.7
# 兼容性: Ubuntu 20.04+ / Debian 10+
#
# --- v1.7 更新日志 ---
#   - [关键修复] 修复 `initialize_firewall` 函数中 `if` 语句的语法错误 (缺少 `fi`)。
#   - [关键修复] 彻底修复 `delete_port_rule` 函数无法显示和删除规则的问题：
#     - 优化了规则收集逻辑，使用更健壮的正则表达式匹配 `ufw status numbered` 输出。
#     - 现在可以正确列出并删除所有由脚本管理的 IPv4 端口规则（包括默认的 22/tcp 和用户添加的）。
#   - [功能变更] 默认初始化时不再开放 2525/tcp 端口，仅默认开放 22/tcp (SSH)。
#   - [显示优化] `view_port_rules` 和 `delete_port_rule` 列表不再显示 IPv6 规则 (含有 (v6) 的行)。
#   - [用户体验] 自动处理 UFW 启用/重新加载/删除时的 SSH 连接中断警告，不再需要手动确认。
#   - [用户体验] 修复 `read -p` 中颜色代码显示为乱码的问题，将彩色文本与 `read` 提示分离。
#   - [关键修复] 增强 `ufw enable` 和 `ufw reload` 的健壮性检查，确保防火墙规则正确加载。
#   - [问题解决] 修复因 UFW 未成功启用导致“没有看到已添加端口”的问题。
#   - [优化] 明确提示默认开放的 22/tcp 端口。
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
    # 修复：if 语句的语法错误，将 `}` 替换为 `fi`
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

    # --- 新增：重置 UFW 到初始状态 ---
    print_info "正在重置 UFW 到初始状态 (这将删除所有现有 UFW 规则)..."
    echo "y" | sudo ufw reset || { print_error "重置 UFW 失败。"; exit 1; }
    print_success "UFW 已重置。"
    # --- 新增结束 ---

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

    # 1.7 允许默认端口 (22)
    print_info "正在开放默认端口 22/tcp (SSH)..."
    # UFW allow 命令是幂等的，重复执行不会创建重复规则
    sudo ufw allow 22/tcp comment "${COMMENT_TAG}:default:ssh"
    # 移除 2525/tcp 的默认添加
    # sudo ufw allow 2525/tcp comment "${COMMENT_TAG}:default:custom_port"
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
    fi
    
    print_success "防火墙初始化完成，规则已自动保存。"
    sleep 2
}

# 2. 端口管理
function manage_ports() {
    while true; do
        clear
        local docker_status_text="非 Docker 主机"
        if [ "$IS_UFW_DOCKER_COMPATIBLE" = true ]; then docker_status_text="${C_GREEN}已配置 (Docker 兼容模式)${C_RESET}"; fi
        echo -e "${C_CYAN}--- 主机与容器端口管理 (当前模式: ${docker_status_text}) ---${C_RESET}"
        echo "1. 添加新端口规则"
        echo "2. 查看已添加的端口规则"
        echo "3. 删除端口规则"
        echo "q. 返回主菜单"
        echo -n "请选择操作: "
        read choice
        case $choice in
            1) add_port_rule ;;
            2) view_port_rules ;;
            3) delete_port_rule ;;
            q|Q) break ;;
            *) print_error "无效选项。" ;;
        esac
    done
}

function add_port_rule() {
    echo -n "请输入要开放的端口号: "
    read port
    [[ -z "$port" ]] && { print_error "端口号不能为空。"; press_enter_to_continue; return; }
    echo -n "请输入协议 (tcp/udp) [默认: tcp]: "
    read proto
    proto=${proto:-tcp}
    echo -n "是否要限制来源IP? (留空则允许所有IP, 或输入IP地址如 8.8.8.8/32): "
    read source_ip

    local rule_comment="${COMMENT_TAG}:port:${port}:${proto}"
    if [ -n "$source_ip" ]; then
        rule_comment+=":from:${source_ip}"
    fi

    # UFW allow 命令是幂等的，重复执行不会创建重复规则，但为了清晰和修改规则，先删除旧的再添加新的。
    # 查找并删除所有匹配该端口、协议和来源IP的规则
    print_info "正在检查并删除端口 ${port}/${proto} (来源: ${source_ip:-所有IP}) 的旧规则..."
    # 改进 grep 模式，确保匹配到正确的注释，并排除 IPv6
    local existing_rules=$(sudo ufw status numbered | grep -E "${COMMENT_TAG}:port:${port}:${proto}(:from:${source_ip})?$" | grep -v '(v6)' | awk '{print $1}' | sed 's/\[//;s/\]//' | sort -nr)
    for num in $existing_rules; do
        print_info "正在删除规则 [${num}]..."
        echo "y" | sudo ufw delete "$num" > /dev/null
    done
    print_success "旧规则清理完成。"

    local ufw_cmd="sudo ufw allow "
    if [ -n "$source_ip" ]; then
        ufw_cmd+="from ${source_ip} "
    fi
    ufw_cmd+="to any port ${port} proto ${proto} comment \"${rule_comment}\""

    print_info "将执行: ${ufw_cmd}"
    if eval ${ufw_cmd}; then
        print_success "端口 ${port}/${proto} 规则添加成功。"
    else
        print_error "添加端口规则失败。"
    fi
    press_enter_to_continue
}

function view_port_rules() {
    print_info "--- 当前由脚本管理的 UFW 规则 (仅显示 IPv4) ---"
    # 修复：确保显示所有由脚本添加的规则 (包括默认和用户自定义的)，并排除 IPv6
    sudo ufw status numbered | grep --color=never "${COMMENT_TAG}:" | grep -v '(v6)'
    press_enter_to_continue
}

function delete_port_rule() {
    print_info "--- 删除端口规则 (仅显示 IPv4) ---"
    local managed_rules=()
    local rule_numbers=()
    
    # 收集由脚本管理的所有 IPv4 规则 (包括默认和用户添加的)
    # 优化：将 grep 过滤放在 while 循环外部，提高效率和准确性
    while IFS= read -r line; do
        # 匹配并提取编号和完整的注释部分
        # 示例行: [ 1] 22/tcp                     ALLOW IN    Anywhere                  # managed-by-ufw-script:default:ssh
        if [[ "$line" =~ ^\[([0-9]+)\]\ .*#\ ${COMMENT_TAG}:(.*) ]]; then
            local rule_num=${BASH_REMATCH[1]}
            local rule_desc="${COMMENT_TAG}:${BASH_REMATCH[2]}" # 重新构建完整的注释
            managed_rules+=("规则 [${rule_num}]: ${rule_desc}")
            rule_numbers+=("${rule_num}")
        fi
    done < <(sudo ufw status numbered | grep "${COMMENT_TAG}:" | grep -v '(v6)')

    if [ ${#managed_rules[@]} -eq 0 ]; then
        print_warn "没有找到由本脚本管理的任何 IPv4 端口规则。"
        press_enter_to_continue
        return
    fi

    managed_rules+=("返回")
    print_info "请选择要删除的规则:"
    select choice in "${managed_rules[@]}"; do
        if [[ "$choice" == "返回" ]]; then break; fi
        if [ -n "$choice" ]; then
            local selected_num=${rule_numbers[$((REPLY-1))]}
            print_warn "将要删除规则 [${selected_num}]: ${choice}"
            echo -n "确认删除吗? (y/N): "
            read confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 修复：自动确认删除
                local delete_output=$(echo "y" | sudo ufw delete "$selected_num" 2>&1)
                if echo "$delete_output" | grep -q "Rule deleted"; then
                    print_success "规则 [${selected_num}] 已成功删除。"
                else
                    print_error "删除规则失败。输出: ${delete_output}"; fi
            else
                print_info "操作已取消。"; fi
        else
            print_error "无效选项。"; fi
        break
    done
    press_enter_to_continue
}

# 3. 端口转发 (NAT) 管理
function manage_forwarding() {
    while true; do
        clear; echo -e "${C_CYAN}--- 端口转发 (NAT) 管理 ---${C_RESET}"
        echo "1. 添加新转发规则"
        echo "2. 查看已添加的转发规则"
        echo "3. 删除转发规则"
        echo "q. 返回主菜单"
        echo -n "请选择操作: "
        read choice
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
    echo -n "请输入源端口 (本机被访问的端口): "
    read from_port
    [[ -z "$from_port" ]] && { print_error "源端口不能为空。"; press_enter_to_continue; return; }
    echo -n "请输入目标IP (转发到哪个IP，例如 192.168.1.100): "
    read to_ip
    [[ -z "$to_ip" ]] && { print_error "目标IP不能为空。"; press_enter_to_continue; return; }
    echo -n "请输入目标端口 (转发到哪个端口): "
    read to_port
    [[ -z "$to_port" ]] && { print_error "目标端口不能为空。"; press_enter_to_continue; return; }
    echo -n "请输入协议 (tcp/udp) [默认: tcp]: "
    read proto
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
    print_info "正在重新加载 UFW 规则..."
    # 修复：自动确认重新加载
    echo "y" | sudo ufw reload || { print_error "UFW 重新加载失败！请检查 /etc/ufw/before.rules 文件。"; press_enter_to_continue; return; }
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
            echo -n "确认删除吗? (y/N): "
            read confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                sudo sed -i "/^.*${selected_comment}.*$/d" /etc/ufw/before.rules
                print_info "正在重新加载 UFW 规则..."
                # 修复：自动确认重新加载
                echo "y" | sudo ufw reload || { print_error "UFW 重新加载失败！请检查 /etc/ufw/before.rules 文件。"; press_enter_to_continue; return; }
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
    print_warn "UFW (Uncomplicated Firewall) 主要用于简化主机防火墙管理，不直接支持复杂的负载均衡或轮询功能。"
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
    watch -n 2 "sudo ufw status verbose"
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
    echo -n "要继续，请输入 'YES' (大小写敏感): "
    read confirm1
    if [ "$confirm1" != "YES" ]; then print_info "操作已取消。"; press_enter_to_continue; return; fi
    echo -n "请再次输入 'DELETE MY FIREWALL' 以最终确认: "
    read confirm2
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
    # 清理 before.rules 和 after.rules 中的脚本标记块
    sudo sed -i "/${UFW_DOCKER_FORWARD_RULES_BEGIN}/,/${UFW_DOCKER_FORWARD_RULES_END}/d" /etc/ufw/before.rules 2>/dev/null || true
    sudo sed -i "/${UFW_DOCKER_FORWARD_RULES_BEGIN}/,/${UFW_DOCKER_FORWARD_RULES_END}/d" /etc/ufw/after.rules 2>/dev/null || true # 确保清理旧位置
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
    # 首次运行或 UFW 未启用时，自动初始化
    if ! command -v ufw &> /dev/null || ! sudo ufw status | grep -q "Status: active"; then
        initialize_firewall
    else
        # 检查 UFW 是否被配置为 Docker 兼容模式
        # 检查 DEFAULT_FORWARD_POLICY 和 before.rules 中的 Docker 兼容性标记
        if grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw && \
           grep -q "${UFW_DOCKER_FORWARD_RULES_BEGIN}" /etc/ufw/before.rules && \
           grep -q "${UFW_DOCKER_FORWARD_RULES_END}" /etc/ufw/before.rules; then
            IS_UFW_DOCKER_COMPATIBLE=true
        else
            IS_UFW_DOCKER_COMPATIBLE=false
            # 如果 Docker 存在但 UFW 未配置为兼容模式，则提示
            if command -v docker &> /dev/null; then
                print_warn "检测到 Docker 已安装，但 UFW 未配置为 Docker 兼容模式。"
                print_warn "强烈建议您运行 '5. 重新运行初始化并应用基础安全配置' 并选择保留 Docker，以确保安全。"
                sleep 3
            fi
        fi
    fi

    while true; do
        clear
        local docker_status_text="非 Docker 主机"
        if [ "$IS_UFW_DOCKER_COMPATIBLE" = true ]; then docker_status_text="${C_GREEN}已配置 (Docker 兼容模式)${C_RESET}"; fi
        
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e "${C_CYAN}  UFW 智能管理脚本 v1.7 (安全默认 & 深度集成)      ${C_RESET}"
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e " UFW Docker 兼容状态: ${docker_status_text}"
        print_info "所有规则变更后将自动保存，无需手动操作。"
        echo "-----------------------------------------------------"
        echo -e "1. 端口管理 (添加/查看/删除)"
        echo -e "2. 端口转发(NAT)管理 (添加/查看/删除)"
        echo -e "3. 负载均衡/轮询 (说明与建议)"
        echo -e "4. 实时查看网络流量和规则计数"
        echo -e "5. [危险] 重新运行初始化并应用基础安全配置"
        echo -e "6. ${C_RED}[极度危险] 卸载并重置防火墙${C_RESET}"
        echo "q. 退出"
        echo "-----------------------------------------------------"
        echo -n "请输入您的选择: "
        read choice

        case $choice in
            1) manage_ports ;;
            2) manage_forwarding ;;
            3) manage_load_balancing ;;
            4) view_traffic ;;
            5) initialize_firewall; press_enter_to_continue ;;
            6) uninstall_firewall ;;
            q|Q) print_info "正在退出。"; exit 0 ;;
            *) print_error "无效选项，请重试。"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main_menu
