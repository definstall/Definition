#!/bin/bash

# ==============================================================================
# iptables 智能管理脚本 v2.6 (Docker 感知)
# 作者: 你的高级软件工程师
# 版本: 2.6
# 兼容性: Ubuntu 20.04+
# 功能:
#   - [改进] 删除端口规则的交互方式，更简单直观。
#   - [修复] 修复了主菜单颜色代码显示问题。
#   - 自动处理 UFW 与 iptables 的冲突
#   - Docker 感知，自动应用规则到 DOCKER-USER 链
#   - 交互式端口管理 (开放/限制/查看/删除)
#   - 交互式端口转发 (NAT) 管理
#   - 内置安全加固 (防扫描, 防SYN Flood)
#   - 实时流量监控
#   - 彻底卸载并重置防火墙功能
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
DOCKER_EXISTS=false
INPUT_CHAIN="INPUT" 
COMMENT_TAG="managed-by-script"

# --- 核心功能函数 ---

# 1. 初始化与环境检测 (与上一版相同)
function initialize_firewall() {
    print_info "开始初始化防火墙配置..."
    if [[ $EUID -ne 0 ]]; then print_error "此脚本必须以 root 权限运行。"; exit 1; fi
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
    if ! dpkg -l | grep -q iptables-persistent; then
        print_info "正在安装 iptables-persistent 以实现规则持久化..."
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        apt-get install -y iptables-persistent > /dev/null
        print_success "iptables-persistent 安装完成。"
    fi
    systemctl enable netfilter-persistent.service &>/dev/null
    if command -v docker &> /dev/null; then
        DOCKER_EXISTS=true; INPUT_CHAIN="DOCKER-USER"
        print_success "检测到 Docker 已安装，所有入站规则将应用到 '${INPUT_CHAIN}' 链。"
    else
        DOCKER_EXISTS=false; INPUT_CHAIN="INPUT"
        print_warn "未检测到 Docker，所有入站规则将应用到 'INPUT' 链。"
    fi
    print_info "正在应用基础安全规则集..."
    iptables -F INPUT; iptables -F FORWARD; iptables -F OUTPUT
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    print_info "正在添加安全加固规则..."
    iptables -A INPUT -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    iptables -A INPUT -p tcp --syn -j DROP
    print_info "正在开放默认端口 22/tcp (SSH) 和 2525/tcp..."
    iptables -A ${INPUT_CHAIN} -p tcp --dport 22 -m comment --comment "${COMMENT_TAG}:default:ssh" -j ACCEPT
    iptables -A ${INPUT_CHAIN} -p tcp --dport 2525 -m comment --comment "${COMMENT_TAG}:default:2525" -j ACCEPT
    save_rules
    print_success "防火墙初始化完成并已保存规则。"
    sleep 2
}

# 保存规则 (与上一版相同)
function save_rules() {
    print_info "正在持久化保存所有 iptables 规则..."
    if [ "$DOCKER_EXISTS" = true ]; then
        print_info "包含 DOCKER-USER 链在内的所有规则都将被保存。"
    fi
    if netfilter-persistent save > /dev/null; then
        print_success "规则已成功保存到 /etc/iptables/rules.v4"
    else
        print_error "保存规则失败！"
    fi
}

# 2. 端口管理
function manage_ports() {
    while true; do
        clear; echo -e "${C_CYAN}--- 端口开放管理 (规则应用到: ${INPUT_CHAIN}) ---${C_RESET}"
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

# 添加端口规则 (与上一版相同)
function add_port_rule() {
    read -p "请输入要开放的端口号: " port
    read -p "请输入协议 (tcp/udp) [默认: tcp]: " proto
    proto=${proto:-tcp}
    read -p "是否要限制来源IP? (留空则允许所有IP, 或输入IP地址如 8.8.8.8): " source_ip
    local existing_rules=$(iptables -S ${INPUT_CHAIN} | grep "\-\-dport ${port} " | grep "\-p ${proto} ")
    if [ -n "$existing_rules" ]; then
        print_warn "检测到端口 ${port}/${proto} 已有规则，将先删除旧规则再添加新规则。"
        iptables -S ${INPUT_CHAIN} | grep "\-\-dport ${port} " | grep "\-p ${proto} " | tac | while read -r rule; do
            iptables -D ${INPUT_CHAIN} ${rule#"-A ${INPUT_CHAIN} "}
        done
    fi
    local rule_comment="${COMMENT_TAG}:port:${port}:${proto}"
    local cmd="iptables -A ${INPUT_CHAIN} -p ${proto} --dport ${port}"
    if [ -n "$source_ip" ]; then
        cmd+=" -s ${source_ip}"
        rule_comment+=":from:${source_ip}"
    fi
    cmd+=" -m comment --comment \"${rule_comment}\" -j ACCEPT"
    print_info "将执行命令: ${cmd}"
    if eval ${cmd}; then print_success "端口 ${port}/${proto} 规则添加成功。"; save_rules; else print_error "添加规则失败。"; fi
    press_enter_to_continue
}

# 查看端口规则 (与上一版相同)
function view_port_rules() {
    print_info "--- 当前由脚本管理的端口规则 (${INPUT_CHAIN} 链) ---"
    iptables -L ${INPUT_CHAIN} -n --line-numbers | grep "${COMMENT_TAG}"
    press_enter_to_continue
}

# [重大改进] 删除端口规则
function delete_port_rule() {
    print_info "--- 删除端口规则 (将删除指定端口的所有相关规则) ---"
    
    # 智能提取所有被管理的端口号，并去重
    local ports=($(iptables -S ${INPUT_CHAIN} | grep "${COMMENT_TAG}" | grep -oP '(?<=--dport )\d+' | sort -u))
    
    if [ ${#ports[@]} -eq 0 ]; then
        print_warn "没有找到由本脚本管理的端口规则。"
        press_enter_to_continue
        return
    fi

    print_info "请选择要删除规则的端口号:"
    ports+=("返回")
    select port_to_delete in "${ports[@]}"; do
        if [[ "$port_to_delete" == "返回" ]]; then break; fi
        if [ -n "$port_to_delete" ]; then
            print_warn "将要删除端口 ${port_to_delete} 的所有相关规则 (TCP/UDP, 所有IP限制)。"
            read -p "确认删除吗? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                local all_deleted=true
                # 查找并逆序删除所有与该端口相关的规则
                iptables -S ${INPUT_CHAIN} | grep "\-\-dport ${port_to_delete} " | grep "${COMMENT_TAG}" | tac | while read -r rule; do
                    print_info "正在删除: ${rule#"-A ${INPUT_CHAIN} "}"
                    if ! iptables -D ${INPUT_CHAIN} ${rule#"-A ${INPUT_CHAIN} "}; then
                        all_deleted=false
                    fi
                done

                if $all_deleted; then
                    print_success "端口 ${port_to_delete} 的所有规则已成功删除。"
                    save_rules
                else
                    print_error "删除过程中发生错误，请检查。"
                fi
            else
                print_info "操作已取消。"
            fi
        else
            print_error "无效选项。"
        fi
        break
    done
    press_enter_to_continue
}

# 3. 端口转发 (NAT) (与上一版相同)
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
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    local rule_comment="${COMMENT_TAG}:fwd:${from_port}:to:${to_ip}:${to_port}"
    local cmd1="iptables -t nat -A PREROUTING -p tcp --dport ${from_port} -m comment --comment \"${rule_comment}\" -j DNAT --to-destination ${to_ip}:${to_port}"
    local cmd2="iptables -t nat -A OUTPUT -p tcp --dport ${from_port} -d 127.0.0.1 -m comment --comment \"${rule_comment}\" -j DNAT --to-destination ${to_ip}:${to_port}"
    print_info "将执行以下命令:"; echo $cmd1; echo $cmd2
    if eval ${cmd1} && eval ${cmd2}; then print_success "端口转发规则添加成功。"; save_rules; else print_error "添加转发规则失败。"; fi
    press_enter_to_continue
}

function view_forwarding_rules() {
    print_info "--- 当前由脚本管理的转发规则 (nat 表) ---"
    echo "--- PREROUTING 链 (外部流量) ---"; iptables -t nat -L PREROUTING -n --line-numbers | grep "${COMMENT_TAG}"
    echo "--- OUTPUT 链 (本机流量) ---"; iptables -t nat -L OUTPUT -n --line-numbers | grep "${COMMENT_TAG}"
    press_enter_to_continue
}

function delete_forwarding_rule() {
    print_error "删除转发规则功能较复杂，请手动执行 'iptables -t nat -D CHAIN RULE_NUMBER'。"; print_warn "您可以使用 '查看已添加的转发规则' 功能获取链(CHAIN)和规则编号(RULE_NUMBER)。"; press_enter_to_continue
}

# 4. 实时流量监控 (与上一版相同)
function view_traffic() {
    print_info "正在启动实时流量监控... (按 Ctrl+C 退出)"
    sleep 1
    watch -n 2 "iptables -nvL && [ \"${DOCKER_EXISTS}\" = true ] && echo -e \"\n--- Docker 链 ---\" && iptables -nvL DOCKER-USER"
}

# 卸载功能 (与上一版相同)
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
    if [ ! -f "/etc/iptables/rules.v4" ]; then
        initialize_firewall
    fi
    if command -v docker &> /dev/null; then DOCKER_EXISTS=true; INPUT_CHAIN="DOCKER-USER"; else DOCKER_EXISTS=false; INPUT_CHAIN="INPUT"; fi

    while true; do
        clear
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e "${C_CYAN}      iptables 智能管理脚本 v2.6 (Docker 感知)       ${C_RESET}"
        echo -e "${C_CYAN}=====================================================${C_RESET}"
        echo -e " Docker 状态: ${DOCKER_EXISTS} | 当前规则目标链: ${C_YELLOW}${INPUT_CHAIN}${C_RESET}"
        echo "-----------------------------------------------------"
        echo -e "1. 端口开放管理 (添加/查看/删除)"
        echo -e "2. 端口转发(NAT)管理 (添加/查看/删除)"
        echo -e "3. 实时查看网络流量和规则计数"
        echo -e "4. 手动保存当前所有规则"
        echo -e "5. [危险] 重新运行初始化并应用基础安全配置"
        echo -e "6. ${C_RED}[极度危险] 卸载并重置防火墙${C_RESET}"
        echo -e "q. 退出"
        echo "-----------------------------------------------------"
        read -p "请输入您的选择: " choice

        case $choice in
            1) manage_ports ;;
            2) manage_forwarding ;;
            3) view_traffic ;;
            4) save_rules; press_enter_to_continue ;;
            5) initialize_firewall; press_enter_to_continue ;;
            6) uninstall_firewall ;;
            q|Q) print_info "正在退出。"; exit 0 ;;
            *) print_error "无效选项，请重试。"; sleep 1 ;;
        esac
    done
}

# --- 脚本入口 ---
main_menu
