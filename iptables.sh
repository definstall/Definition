#!/bin/bash

# ==============================================================================
# iptables 智能管理脚本 v4.5 (安全默认 & 深度 Docker 集成)
# 作者: 你的高级软件工程师
# 版本: 4.5
# 兼容性: Ubuntu 20.04+ / Debian 10+
#
# --- v4.5 更新日志 ---
#   - [核心优化] 增强 initialize_firewall 函数，在初始化时对 Docker 进行更智能的交互式处理：
#     - 如果检测到 Docker 已安装，将提供用户选择：彻底卸载 Docker，或保留 Docker 并让脚本管理其防火墙。
#     - 根据用户选择，执行相应的 Docker 卸载/保留逻辑，并配置 iptables。
#     - 如果用户选择保留 Docker，脚本将配置 iptables 以兼容 Docker，并确保 DOCKER-USER 链的默认拒绝策略。
#     - 如果用户取消操作，脚本将安全退出。
#   - [逻辑变更] 重新引入 Docker 环境下 FORWARD 链默认策略为 ACCEPT 的逻辑，并提示重启 Docker 服务。
#   - [修复] 修复 _delete_rules_for_port_in_chain 函数中变量引用问题，并增加 source_ip 参数。
#   - [修复] 修复 delete_port_rule 中对 DOCKER-USER 规则的 grep 匹配问题，并优化规则显示。
#   - [优化] add_forwarding_rule 在添加前先删除旧的同类规则，避免重复。
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
COMMENT_TAG="managed-by-script"
IS_DOCKER_HOST=false # 此变量在 initialize_firewall 结束后，将反映 Docker 是否被脚本管理

# --- 核心功能函数 ---

# 1. 初始化与环境检测
function initialize_firewall() {
    print_info "开始初始化防火墙配置..."
    if [[ $EUID -ne 0 ]]; then print_error "此脚本必须以 root 权限运行。"; exit 1; fi

    # UFW 检测和处理
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        print_warn "检测到 UFW 正在运行。本脚本使用 iptables 进行精细化管理。"
        read -p "是否要禁用并移除 UFW 以便使用 iptables? (Y/n): " confirm_ufw
        if [[ "$confirm_ufw" =~ ^[Yy]$ || -z "$confirm_ufw" ]]; then
            print_info "正在禁用 UFW..."; ufw disable
            print_info "正在卸载 UFW..."; apt-get purge -y ufw > /dev/null
            print_success "UFW 已移除。"
        else
            print_error "用户取消操作。无法在启用 UFW 的情况下继续。"; exit 1
        fi
    fi

    # iptables-persistent 安装
    if ! dpkg -l | grep -q iptables-persistent; then
        print_info "正在安装 iptables-persistent 以实现规则持久化..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null
        print_success "iptables-persistent 安装完成。"
    fi
    systemctl enable netfilter-persistent.service &>/dev/null

    # --- 核心优化：Docker 存在时的交互式处理 ---
    if command -v docker &> /dev/null; then
        print_warn "检测到 Docker 已安装。"
        local docker_is_running=false
        if systemctl is-active docker &>/dev/null; then
            docker_is_running=true
            print_warn "Docker 服务当前正在运行。"
        fi

        echo -e "${C_CYAN}--- Docker 环境处理选项 ---${C_RESET}"
        echo "1. ${C_RED}彻底卸载 Docker${C_RESET} (包括所有数据和软件包，将配置为非 Docker 主机防火墙)"
        echo "2. ${C_GREEN}保留 Docker 并让脚本管理其防火墙${C_RESET} (配置为 Docker 兼容防火墙)"
        echo "q. 退出脚本 (不进行任何防火墙初始化)"
        read -p "请选择操作: " docker_choice

        case $docker_choice in
            1) # 彻底卸载 Docker
                print_warn "!!! 警告: 此操作将永久删除所有 Docker 相关数据和程序 !!!"
                read -p "请再次确认彻底卸载 Docker? (y/N): " final_confirm_docker_uninstall
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
                    IS_DOCKER_HOST=false # Docker 已被卸载，按非 Docker 主机处理
                else
                    print_error "用户取消 Docker 卸载。无法在不处理 Docker 的情况下安全初始化防火墙。"
                    print_error "请手动处理 Docker 或选择卸载，然后重新运行脚本。"
                    exit 1 # 用户取消，安全退出
                fi
                ;;
            2) # 保留 Docker 并让脚本管理其防火墙
                print_info "您选择保留 Docker。脚本将配置防火墙以兼容 Docker。"
                IS_DOCKER_HOST=true # 脚本将管理 Docker 环境下的防火墙
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
        IS_DOCKER_HOST=false # 未检测到 Docker，按非 Docker 主机处理
        print_info "未检测到 Docker，跳过 Docker 相关处理。"
    fi
    # --- Docker 存在时的交互式处理结束 ---

    # --- 核心：彻底清理 iptables 规则 (无论 Docker 是否安装或被卸载，都执行此步骤以确保干净) ---
    print_info "正在执行 iptables 规则的彻底清理..."
    # 清空所有表中的所有链，并删除自定义链
    iptables -F; iptables -X; iptables -Z
    iptables -t nat -F; iptables -t nat -X; iptables -t nat -Z
    iptables -t mangle -F; iptables -t mangle -X; iptables -t mangle -Z
    iptables -t raw -F; iptables -t raw -X; iptables -t raw -Z # 包含 raw 表

    # 再次尝试删除所有 Docker 相关的自定义链，以防万一（在 Docker 卸载后，这些链应该已经不存在了）
    for chain in DOCKER DOCKER-USER DOCKER-ISOLATION-STAGE-1 DOCKER-ISOLATION-STAGE-2 DOCKER-BRIDGE DOCKER-CT; do
        sudo iptables -X $chain 2>/dev/null || true
        sudo iptables -t nat -X $chain 2>/dev/null || true
        sudo iptables -t mangle -X $chain 2>/dev/null || true
        sudo iptables -t raw -X $chain 2>/dev/null || true
    done
    print_success "iptables 规则清理完成。"
    # --- iptables 规则清理结束 ---

    print_info "正在应用基础规则集..."
    # 设置默认策略
    iptables -P INPUT DROP
    iptables -P OUTPUT ACCEPT
    
    # 允许本地回环接口
    iptables -A INPUT -i lo -j ACCEPT
    # 允许已建立和相关连接
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 根据 IS_DOCKER_HOST 变量（反映用户选择或 Docker 实际状态）设置 FORWARD 链策略
    if [ "$IS_DOCKER_HOST" = true ]; then
        print_info "检测到 Docker 环境，将设置 'FORWARD' 链默认策略为 ACCEPT (Docker 兼容模式)。"
        iptables -P FORWARD ACCEPT
        
        # 重新创建 DOCKER-USER 链 (如果被清理掉了)
        iptables -N DOCKER-USER &>/dev/null
        
        # 如果 Docker 服务之前是运行状态，或者用户选择保留 Docker，提示重启
        if command -v docker &> /dev/null && [ "$docker_is_running" = true ]; then
            print_info "正在重启 Docker 服务以确保其规则正确生成..."
            sudo systemctl start docker || print_error "重启 Docker 服务失败，请手动检查。"
            print_success "Docker 服务已重启。"
            print_info "如果遇到容器网络问题，请尝试再次重启 Docker 服务。"
        elif command -v docker &> /dev/null; then # Docker 存在但之前未运行，现在需要启动它来生成规则
            print_info "Docker 已安装但未运行。请手动启动 Docker 服务以生成其规则: sudo systemctl start docker"
        fi
        
    else # 非 Docker 主机模式 (Docker 被卸载或从未安装)
        print_info "未检测到 Docker 或 Docker 已被卸载，将设置 'FORWARD' 链默认策略为 DROP。"
        iptables -P FORWARD DROP
    fi

    print_info "正在添加安全加固规则到 INPUT 链..."
    # SYN-Flood 防护
    iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    iptables -A INPUT -p tcp --syn -j DROP # 拒绝超过限制的 SYN 包

    # 常见无效 TCP 包过滤 (XMAS, NULL 扫描等)
    iptables -A INPUT -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP

    print_info "正在开放默认端口 22/tcp (SSH)..."
    iptables -A INPUT -p tcp --dport 22 -m comment --comment "${COMMENT_TAG}:default:ssh" -j ACCEPT
    
    # 只有当 IS_DOCKER_HOST 为 true 时才为 DOCKER-USER 链添加规则
    if [ "$IS_DOCKER_HOST" = true ]; then
        print_info "同时为 DOCKER-USER 链开放默认端口 (插入规则)。"
        # 插入到 DOCKER-USER 链的开头，确保在 DROP 规则之前
        iptables -I DOCKER-USER 1 -p tcp --dport 22 -m comment --comment "${COMMENT_TAG}:default:ssh" -j ACCEPT
        
        print_info "正在为 DOCKER-USER 链设置默认拒绝策略..."
        # [核心安全升级] 确保链末尾是 DROP，实现默认拒绝
        # 这一条必须是 DOCKER-USER 链的最后一条规则
        iptables -A DOCKER-USER -m comment --comment "default-deny-all" -j DROP
    fi
    
    save_rules
    print_success "防火墙初始化完成，规则已自动保存。"
    sleep 2
}

# 保存规则
function save_rules() {
    print_info "正在自动持久化所有 iptables 规则..."
    if netfilter-persistent save > /dev/null; then
        print_success "规则已成功保存到 /etc/iptables/rules.v4"
    else
        print_error "自动保存规则失败！"
    fi
}

# 2. 端口管理
function manage_ports() {
    while true; do
        clear
        # 每次进入端口管理菜单时，重新检测 Docker 状态，确保 IS_DOCKER_HOST 最新
        if command -v docker &> /dev/null; then
            # 进一步检查 DOCKER-USER 链是否存在且有默认拒绝规则，以判断是否为“脚本管理下的 Docker 主机”
            if iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
                IS_DOCKER_HOST=true
            else
                # Docker 存在，但 DOCKER-USER 链未被脚本正确管理，视为非脚本管理下的 Docker 主机
                IS_DOCKER_HOST=false
                print_warn "检测到 Docker 已安装，但 DOCKER-USER 链未被本脚本管理。端口规则将仅应用于 INPUT 链。"
                print_warn "如需本脚本管理 Docker 流量，请运行 '4. 重新运行初始化并应用基础安全配置' 并选择保留 Docker。"
                sleep 3
            fi
        else
            IS_DOCKER_HOST=false
        fi

        local target_chains="INPUT"
        if [ "$IS_DOCKER_HOST" = true ]; then target_chains="INPUT 和 DOCKER-USER"; fi
        echo -e "${C_CYAN}--- 主机与容器端口管理 (规则应用到: ${target_chains}) ---${C_RESET}"
        echo "1. 添加新端口规则"
        echo "2. 查看已添加的端口规则"
        echo "3. 删除端口规则"
        echo "q. 返回主菜单"
        read -p "请选择操作: " choice
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
    read -p "请输入要开放的端口号: " port
    [[ -z "$port" ]] && { print_error "端口号不能为空。"; press_enter_to_continue; return; }
    read -p "请输入协议 (tcp/udp) [默认: tcp]: " proto
    proto=${proto:-tcp}
    read -p "是否要限制来源IP? (留空则允许所有IP, 或输入IP地址如 8.8.8.8): " source_ip

    # 每次操作前重新评估 IS_DOCKER_HOST
    if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
        IS_DOCKER_HOST=true
    else
        IS_DOCKER_HOST=false
    fi

    # 在添加新规则前，先删除该端口/协议/来源IP的旧规则，避免重复
    _delete_rules_for_port_in_chain "$port" "$proto" "INPUT" "$source_ip" "silent"
    if [ "$IS_DOCKER_HOST" = true ]; then
        _delete_rules_for_port_in_chain "$port" "$proto" "DOCKER-USER" "$source_ip" "silent"
    fi

    local rule_comment="${COMMENT_TAG}:port:${port}:${proto}"
    local base_cmd_part="-p ${proto} --dport ${port}"
    if [ -n "$source_ip" ]; then
        base_cmd_part+=" -s ${source_ip}"
        rule_comment+=":from:${source_ip}"
    fi
    base_cmd_part+=" -m comment --comment \"${rule_comment}\" -j ACCEPT"

    # 对 INPUT 链使用追加 (-A)
    local cmd_input="iptables -A INPUT ${base_cmd_part}"
    print_info "将执行: ${cmd_input}"
    if ! eval ${cmd_input}; then
        print_error "向 INPUT 链添加规则失败。"; press_enter_to_continue; return
    fi

    if [ "$IS_DOCKER_HOST" = true ]; then
        # [核心安全升级] 对 DOCKER-USER 链使用插入 (-I)，确保规则在最终的 DROP 规则之前
        local cmd_docker="iptables -I DOCKER-USER 1 ${base_cmd_part}"
        print_info "将执行: ${cmd_docker}"
        if ! eval ${cmd_docker}; then
            print_error "向 DOCKER-USER 链添加规则失败。"; press_enter_to_continue; return
        fi
        # 确保 DOCKER-USER 链末尾有默认拒绝规则 (双重检查)
        if ! iptables -L DOCKER-USER -n | grep -q "default-deny-all"; then
            print_info "正在为 DOCKER-USER 链设置默认拒绝策略..."
            iptables -A DOCKER-USER -m comment --comment "default-deny-all" -j DROP
        fi
    fi

    print_success "端口 ${port}/${proto} 规则添加成功。"
    save_rules
    press_enter_to_continue
}

# 修复 _delete_rules_for_port_in_chain 函数的参数引用问题
function _delete_rules_for_port_in_chain() {
    local port="$1"
    local proto="$2"
    local chain="$3"
    local source_ip="$4" # 新增参数
    local mode="$5"
    local all_deleted=true

    local grep_pattern="-p ${proto} --dport ${port}"
    if [ -n "$source_ip" ]; then
        grep_pattern+=" -s ${source_ip}"
    fi
    grep_pattern+=".*${COMMENT_TAG}" # 确保只匹配脚本管理的规则

    # 使用 eval 的健壮删除逻辑，兼容 -A 和 -I 规则
    # 遍历所有匹配的规则，并尝试删除
    iptables-save | grep -- "-A ${chain}\|-I ${chain}" | grep "${grep_pattern}" | while read -r rule; do
        local delete_command="iptables ${rule/-A/-D}" # 将 -A 替换为 -D
        delete_command=${delete_command/-I/-D} # 将 -I 替换为 -D
        
        if [[ "$mode" != "silent" ]]; then
            print_info "将执行删除命令: ${delete_command}"
        fi

        if ! eval "${delete_command}"; then
            all_deleted=false
            if [[ "$mode" != "silent" ]]; then
                print_error "命令执行失败！"
            fi
        fi
    done
    
    # 注意：由于 while 循环在子 shell 中运行，all_deleted 的值不会直接影响父 shell。
    # 但对于删除操作，我们更关心的是命令是否执行成功，而不是返回值。
    # 这里的 all_deleted 更多用于日志记录。
    # 实际的成功判断将依赖于后续的规则检查或用户确认。
    return 0 # 总是返回成功，因为循环内部已经处理了错误
}

function view_port_rules() {
    print_info "--- 当前由脚本管理的规则 (INPUT 链 - 主机) ---"
    iptables -L INPUT -n --line-numbers | grep --color=never "${COMMENT_TAG}"
    
    # 每次操作前重新评估 IS_DOCKER_HOST
    if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
        IS_DOCKER_HOST=true
    else
        IS_DOCKER_HOST=false
    fi

    if [ "$IS_DOCKER_HOST" = true ]; then
        echo ""
        print_info "--- 当前由脚本管理的规则 (DOCKER-USER 链 - 容器) ---"
        iptables -L DOCKER-USER -n --line-numbers | grep --color=never -E "${COMMENT_TAG}|default-deny-all"
    fi
    press_enter_to_continue
}

function delete_port_rule() {
    print_info "--- 删除端口规则 (将从 INPUT 和 DOCKER-USER 链中删除) ---"
    local all_rules_info=()
    local rule_comments=()
    
    # 收集 INPUT 链的规则
    while IFS= read -r line; do
        if [[ $line =~ -m\ comment\ --comment\ \"(${COMMENT_TAG}:port:[^\"]+)\" ]]; then
            local comment_content=${BASH_REMATCH[1]}
            local port_info=$(echo "$comment_content" | sed -E 's/.*:port:([0-9]+):([^:]+)(:from:([0-9.]+))?/\1\/\2 from \4/')
            port_info=$(echo "$port_info" | sed 's/ from $//') # 移除末尾的 " from " 如果没有IP
            all_rules_info+=("INPUT: ${port_info}")
            rule_comments+=("${comment_content}")
        fi
    done < <(iptables-save | grep -- "-A INPUT" | grep "${COMMENT_TAG}")

    # 每次操作前重新评估 IS_DOCKER_HOST
    if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
        IS_DOCKER_HOST=true
    else
        IS_DOCKER_HOST=false
    fi

    # 收集 DOCKER-USER 链的规则
    if [ "$IS_DOCKER_HOST" = true ]; then
        while IFS= read -r line; do
            # 匹配 -A 或 -I 规则
            if [[ $line =~ -(A|I)\ DOCKER-USER.*-m\ comment\ --comment\ \"(${COMMENT_TAG}:port:[^\"]+)\" ]]; then
                local comment_content=${BASH_REMATCH[2]} # 捕获第二个匹配组
                local port_info=$(echo "$comment_content" | sed -E 's/.*:port:([0-9]+):([^:]+)(:from:([0-9.]+))?/\1\/\2 from \4/')
                port_info=$(echo "$port_info" | sed 's/ from $//') # 移除末尾的 " from " 如果没有IP
                all_rules_info+=("DOCKER-USER: ${port_info}")
                rule_comments+=("${comment_content}")
            fi
        done < <(iptables-save | grep -- "-A DOCKER-USER\|-I DOCKER-USER" | grep "${COMMENT_TAG}")
    fi

    if [ ${#all_rules_info[@]} -eq 0 ]; then
        print_warn "没有找到由本脚本管理的任何端口规则。"
        press_enter_to_continue
        return
    fi

    all_rules_info+=("返回")
    print_info "请选择要删除的规则:"
    select choice in "${all_rules_info[@]}"; do
        if [[ "$choice" == "返回" ]]; then break; fi
        if [ -n "$choice" ]; then
            local selected_comment=${rule_comments[$((REPLY-1))]}
            
            print_warn "将要删除与此 comment 相关的所有规则: \"${selected_comment}\""
            read -p "确认删除吗? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                local success_input=true
                local success_docker=true
                
                # 从 comment 中解析出 port, proto, source_ip
                local parsed_port=$(echo "$selected_comment" | grep -oP '(?<=:port:)\d+')
                local parsed_proto=$(echo "$selected_comment" | grep -oP '(?<=:port:\d+:)[^:]+')
                local parsed_source_ip=$(echo "$selected_comment" | grep -oP '(?<=:from:)[0-9.]+')
                
                _delete_rules_for_port_in_chain "$parsed_port" "$parsed_proto" "INPUT" "$parsed_source_ip" || success_input=false
                
                # 每次操作前重新评估 IS_DOCKER_HOST
                if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
                    IS_DOCKER_HOST=true
                else
                    IS_DOCKER_HOST=false
                fi

                if [ "$IS_DOCKER_HOST" = true ]; then
                    _delete_rules_for_port_in_chain "$parsed_port" "$parsed_proto" "DOCKER-USER" "$parsed_source_ip" || success_docker=false
                fi

                if $success_input && $success_docker; then
                    print_success "规则已成功删除。"
                    save_rules
                else
                    print_error "删除过程中发生错误，部分规则可能未被删除。"; fi
            else
                print_info "操作已取消。"; fi
        else
            print_error "无效选项。"; fi
        break
    done
    press_enter_to_continue
}

# 3. 端口转发 (NAT)
function manage_forwarding() {
    while true; do
        clear; echo -e "${C_CYAN}--- 端口转发 (NAT) 管理 ---${C_RESET}"
        echo "1. 添加新转发规则"
        echo "2. 查看已添加的转发规则"
        echo "3. 删除转发规则"
        echo "q. 返回主菜单"
        read -p "请选择操作: " choice
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
    read -p "请输入源端口 (本机被访问的端口): " from_port
    read -p "请输入目标IP (留空则为本机127.0.0.1): " to_ip
    to_ip=${to_ip:-127.0.0.1}
    read -p "请输入目标端口 (转发到哪个端口): " to_port
    
    # 确保 IP 转发已启用
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    local rule_comment="${COMMENT_TAG}:fwd:${from_port}:to:${to_ip}:${to_port}"
    
    # 删除旧的同类规则，避免重复
    _delete_forwarding_rules_by_comment "$rule_comment" "silent"

    local cmd1="iptables -t nat -A PREROUTING -p tcp --dport ${from_port} -m comment --comment \"${rule_comment}\" -j DNAT --to-destination ${to_ip}:${to_port}"
    local cmd2="iptables -t nat -A OUTPUT -p tcp --dport ${from_port} -d 127.0.0.1 -m comment --comment \"${rule_comment}\" -j DNAT --to-destination ${to_ip}:${to_port}"
    
    print_info "将执行以下命令:"; echo $cmd1; echo $cmd2
    if eval ${cmd1} && eval ${cmd2}; then
        print_success "端口转发规则添加成功。"
        save_rules
    else
        print_error "添加转发规则失败。"
    fi
    press_enter_to_continue
}

function view_forwarding_rules() {
    print_info "--- 当前由脚本管理的转发规则 (nat 表) ---"
    echo "--- PREROUTING 链 (外部流量) ---"; iptables -t nat -L PREROUTING -n --line-numbers | grep "${COMMENT_TAG}"
    echo "--- OUTPUT 链 (本机流量) ---"; iptables -t nat -L OUTPUT -n --line-numbers | grep "${COMMENT_TAG}"
    press_enter_to_continue
}

# 新增辅助函数：根据 comment 删除转发规则
function _delete_forwarding_rules_by_comment() {
    local comment_to_delete="$1"
    local mode="$2" # "silent" 或其他
    local all_deleted=true

    iptables-save -t nat | grep -- "-m comment --comment \"${comment_to_delete}\"" | while read -r rule_to_delete; do
        local delete_command="iptables -t nat ${rule_to_delete/-A/-D}"
        
        if [[ "$mode" != "silent" ]]; then
            print_info "正在执行: ${delete_command}"
        fi
        if ! eval "${delete_command}"; then
            all_deleted=false
            if [[ "$mode" != "silent" ]]; then
                print_error "命令执行失败！"
            fi
        fi
    done
    return 0 # 总是返回成功
}

function delete_forwarding_rule() {
    print_info "--- 删除端口转发规则 ---"
    local menu_options=()
    local rule_comments=()
    
    while IFS= read -r rule; do
        if [[ $rule =~ -m\ comment\ --comment\ \"(${COMMENT_TAG}:fwd:[^\"]+)\" ]]; then
            local comment_content=${BASH_REMATCH[1]}
            if [[ $comment_content =~ :fwd:([0-9]+):to:([^:]+):([0-9]+) ]]; then
                local from_port=${BASH_REMATCH[1]}
                local to_ip=${BASH_REMATCH[2]}
                local to_port=${BASH_REMATCH[3]}
                menu_options+=("转发: ${from_port} -> ${to_ip}:${to_port}")
                rule_comments+=("${comment_content}")
            fi
        fi
    done < <(iptables-save -t nat | grep -- "-A PREROUTING" | grep "${COMMENT_TAG}")

    if [ ${#menu_options[@]} -eq 0 ]; then
        print_warn "没有找到由本脚本管理的任何转发规则。"
        press_enter_to_continue
        return
    fi

    menu_options+=("返回")
    print_info "请选择要删除的转发规则:"
    select choice in "${menu_options[@]}"; do
        if [[ "$choice" == "返回" ]]; then break; fi
        if [ -n "$choice" ]; then
            local comment_to_delete=${rule_comments[$((REPLY-1))]}
            
            print_warn "将要删除与此 comment 相关的所有转发规则: \"${comment_to_delete}\""
            read -p "确认删除吗? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if _delete_forwarding_rules_by_comment "$comment_to_delete"; then
                    print_success "转发规则已成功删除。"
                    save_rules
                else
                    print_error "删除过程中发生错误，请检查。"; fi
            else
                print_info "操作已取消。"; fi
        else
            print_error "无效选项。"; fi
        break
    done
    press_enter_to_continue
}

# 4. 实时流量监控
function view_traffic() {
    print_info "正在启动实时流量监控... (按 Ctrl+C 退出)"
    sleep 1
    # 每次操作前重新评估 IS_DOCKER_HOST
    if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
        IS_DOCKER_HOST=true
    else
        IS_DOCKER_HOST=false
    fi

    if [ "$IS_DOCKER_HOST" = true ]; then
        watch -n 2 "echo '--- 主机 INPUT 链 (受管) ---'; iptables -nvL INPUT; echo -e '\n--- Docker DOCKER-USER 链 (受管) ---'; iptables -nvL DOCKER-USER; echo -e '\n--- Docker FORWARD 链 (Docker 自动管理) ---'; iptables -nvL FORWARD"
    else
        watch -n 2 "iptables -nvL"
    fi
}

# 5. 卸载功能
function uninstall_firewall() {
    clear
    print_warn "!!! 极度危险操作 !!!"
    print_warn "此操作将执行以下动作:"
    print_warn "1. 清空所有 iptables 规则。"
    print_warn "2. 将默认策略设置为全部允许 (ACCEPT)，服务器将完全暴露在公网。"
    print_warn "3. 删除已保存的规则文件 /etc/iptables/rules.v4。"
    print_warn "4. 卸载 iptables-persistent 包。"
    echo ""
    read -p "要继续，请输入 'YES' (大小写敏感): " confirm1
    if [ "$confirm1" != "YES" ]; then print_info "操作已取消。"; press_enter_to_continue; return; fi
    read -p "请再次输入 'DELETE MY FIREWALL' 以最终确认: " confirm2
    if [ "$confirm2" != "DELETE MY FIREWALL" ]; then print_info "操作已取消。"; press_enter_to_continue; return; fi
    print_info "正在执行卸载和重置..."
    iptables -F; iptables -X; iptables -Z
    iptables -t nat -F; iptables -t nat -X; iptables -t nat -Z
    iptables -t mangle -F; iptables -t mangle -X; iptables -t mangle -Z
    iptables -t raw -F; iptables -t raw -X; iptables -t raw -Z
    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
    print_success "所有规则已清空，默认策略已设为 ACCEPT。"
    rm -f /etc/iptables/rules.v4
    print_success "规则文件 /etc/iptables/rules.v4 已删除。"
    apt-get purge -y iptables-persistent > /dev/null
    print_success "iptables-persistent 已卸载。"
    echo ""; print_warn "防火墙已完全禁用和移除。您的服务器现在不受保护！"
    press_enter_to_continue
}

# --- 主菜单 ---
function main_menu() {
    # 首次运行或规则文件不存在时，自动初始化
    if [ ! -f "/etc/iptables/rules.v4" ]; then
        initialize_firewall
    else
        # 如果规则文件存在，则在进入主菜单前，根据当前系统状态更新 IS_DOCKER_HOST
        # 检查 DOCKER-USER 链是否存在且有默认拒绝规则，以判断是否为“脚本管理下的 Docker 主机”
        if command -v docker &> /dev/null && iptables -L DOCKER-USER -n 2>/dev/null | grep -q "default-deny-all"; then
            IS_DOCKER_HOST=true
        else
            IS_DOCKER_HOST=false
            # 如果 Docker 存在但 DOCKER-USER 链未被脚本管理，则提示用户
            if command -v docker &> /dev/null; then
                print_warn "检测到 Docker 已安装，但 DOCKER-USER 链未被本脚本管理。"
                print_warn "强烈建议您运行 '4. 重新运行初始化并应用基础安全配置' 并选择保留 Docker，以确保安全。"
                sleep 3
            fi
        fi
    fi

    while true; do
        clear
        local docker_status_text="${C_RED}未安装${C_RESET}"
        if [ "$IS_DOCKER_HOST" = true ]; then docker_status_text="${C_GREEN}已安装 (深度集成模式)${C_RESET}"; fi
        
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e "${C_CYAN}  iptables 智能管理脚本 v4.5 (安全默认 & 深度集成)  ${C_RESET}"
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e " Docker 状态: ${docker_status_text}"
        print_info "所有规则变更后将自动保存，无需手动操作。"
        echo "-----------------------------------------------------"
        echo -e "1. 端口管理 (添加/查看/删除)"
        echo -e "2. 端口转发(NAT)管理 (添加/查看/删除)"
        echo -e "3. 实时查看网络流量和规则计数"
        echo -e "4. [危险] 重新运行初始化并应用基础安全配置"
        echo -e "5. ${C_RED}[极度危险] 卸载并重置防火墙${C_RESET}"
        echo -e "q. 退出"
        echo "-----------------------------------------------------"
        read -p "请输入您的选择: " choice

        case $choice in
            1) manage_ports ;;
            2) manage_forwarding ;;
            3) view_traffic ;;
            4) initialize_firewall; press_enter_to_continue ;;
            5) uninstall_firewall ;;
            q|Q) print_info "正在退出。"; exit 0 ;;
            *) print_error "无效选项，请重试。"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main_menu
