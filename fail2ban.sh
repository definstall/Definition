#!/bin/bash

# ==============================================================================
# Fail2ban 智能生命周期管理脚本
# 作者: 你的高级软件工程师 (由AI助手优化)
# 版本: 8.0 (Ubuntu专用, 增强自愈与诊断能力)
# ==============================================================================

# --- 颜色定义 ---
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'

# --- 辅助函数 ---
function print_error() { echo -e "${C_RED}[错误] $1${C_RESET}"; }
function print_success() { echo -e "${C_GREEN}[成功] $1${C_RESET}"; }
function print_info() { echo -e "${C_BLUE}[信息] $1${C_RESET}"; }
function print_warn() { echo -e "${C_YELLOW}[警告] $1${C_RESET}"; }
function press_enter_to_continue() { echo ""; read -p "按 [Enter] 键返回..."; }

# --- 核心初始化与自愈函数 ---
function initialize_environment() {
    print_info "正在检查运行环境..."; if [[ $EUID -ne 0 ]]; then print_error "此脚本必须以 root 权限运行。"; exit 1; fi
    if [ -f /etc/os-release ]; then . /etc/os-release; if [ "$ID" != "ubuntu" ]; then print_error "此脚本专为 Ubuntu 系统设计。检测到 '$ID'，脚本将退出。"; exit 1; fi; case "$VERSION_ID" in "20.04"|"22.04"|"24.04"|"25.04") print_success "系统版本 '$VERSION_ID' 受支持。";; *) print_error "不支持的 Ubuntu 版本: '$VERSION_ID'。脚本将退出。"; exit 1;; esac; else print_error "无法确定操作系统版本。脚本将退出。"; exit 1; fi
    if ! command -v fail2ban-client &> /dev/null; then print_warn "未检测到 Fail2ban。"; read -p "是否要尝试自动安装 Fail2ban? (Y/n): " install_confirm; if [[ "$install_confirm" =~ ^[Yy]*$ ]]; then print_info "正在使用 apt 安装..."; apt-get update; apt-get install -y fail2ban; if ! command -v fail2ban-client &> /dev/null; then print_error "安装失败。"; exit 1; else print_success "安装成功！"; fi; else print_error "用户取消安装。"; exit 1; fi; fi
    
    # --- 优化点 1: 增强的启动与自愈逻辑 ---
    if ! systemctl is-active --quiet fail2ban; then
        print_warn "服务未运行，正在尝试启动...";
        systemctl start fail2ban
        sleep 1
        if systemctl is-active --quiet fail2ban; then
            print_success "服务启动成功！"
        else
            print_error "Fail2ban 服务启动失败！这通常由配置错误引起。"
            print_info "正在运行配置诊断工具..."
            local test_output
            test_output=$(fail2ban-server -t 2>&1)
            local test_status=$?
            if [ $test_status -ne 0 ]; then
                print_warn "诊断工具发现以下配置问题:"
                echo -e "${C_YELLOW}------------------- 诊断报告 -------------------"
                echo -e "$test_output"
                echo -e "--------------------------------------------------${C_RESET}"
                print_warn "常见原因包括：配置文件语法错误，或 'logpath' 指向了不存在的日志文件。"
                read -p "是否要进入 [移除防护配置] 菜单来尝试修复? (Y/n): " enter_remove_menu
                if [[ "$enter_remove_menu" =~ ^[Yy]*$ ]]; then
                    remove_protection_config
                    print_info "已从修复菜单返回。请重新运行脚本以检查服务状态。"
                else
                    print_info "请手动修复上述问题后，再运行 'systemctl restart fail2ban'。"
                fi
            else
                print_warn "诊断工具未发现明显配置错误，但服务依然无法启动。请手动执行 'sudo journalctl -u fail2ban' 查看详细日志。"
            fi
            exit 1 # 无论如何，在服务启动失败后退出脚本
        fi
    fi

    if ! systemctl is-enabled --quiet fail2ban; then print_info "正在设置开机自启..."; systemctl enable fail2ban; print_success "设置成功。"; fi
    print_success "环境检查通过，Fail2ban 正在正常运行。"; sleep 2
}

# --- 备份函数 ---
function backup_config() { local config_file=$1; if [ ! -f "$config_file" ]; then return; fi; local backup_dir="/etc/fail2ban/backups"; mkdir -p "$backup_dir"; local backup_file="$backup_dir/$(basename "$config_file").$(date +%F_%H-%M-%S).bak"; cp "$config_file" "$backup_file"; print_success "已成功备份当前配置到: $backup_file"; }

# --- 预检机制函数 ---
function test_and_apply_config() {
    local config_content=$1; local target_file=$2;
    # --- 优化点 2: 使用更可靠的 `fail2ban-server -t` 进行预检 ---
    # 我们不再需要临时文件，因为 `fail2ban-server -t` 会检查所有配置。
    # 我们先将新配置写入，然后测试。如果测试失败，再恢复备份。
    
    print_info "正在应用新配置并进行预检测试..."
    backup_config "$target_file"
    echo -e "$config_content" > "$target_file"

    local test_output
    # 使用 fail2ban-server -t 进行离线配置检查
    test_output=$(fail2ban-server -t 2>&1)
    local test_status=$?

    if [ $test_status -ne 0 ]; then
        print_error "配置预检失败！"
        print_warn "Fail2ban 报告了以下错误:"
        echo -e "${C_YELLOW}$test_output${C_RESET}"
        print_info "正在自动从备份中恢复之前的配置..."
        local backup_dir="/etc/fail2ban/backups"
        # 寻找最新的备份文件进行恢复
        local latest_backup=$(ls -t "$backup_dir/$(basename "$target_file")"*.bak 2>/dev/null | head -n 1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$target_file"
            print_success "已成功从 '$latest_backup' 恢复配置。"
        else
            print_warn "未找到备份文件，已将错误的配置文件删除以防服务崩溃。"
            rm "$target_file"
        fi
        print_warn "您的服务和配置未作任何有害更改。"
        return 1
    else
        print_success "配置预检通过。配置文件已创建于 $target_file"
        print_info "正在重新加载 Fail2ban...";
        # 如果服务之前是停止的，则启动；如果是运行的，则重载
        if ! systemctl is-active --quiet fail2ban; then
            if systemctl start fail2ban; then print_success "服务启动成功。"; else print_error "服务启动失败，请检查日志。"; fi
        else
            if fail2ban-client reload; then print_success "重新加载成功。"; else print_error "重新加载失败，请检查日志。"; fi
        fi
        return 0
    fi
}

# --- 主要逻辑函数 (add_ssh_config, add_mysql_config 等保持不变) ---
function view_status_and_logs() { clear; print_info "Fail2ban 状态与日志"; echo "--------------------------------------------------"; select choice in "显示所有活动 jail 的状态" "实时跟踪日志" "返回主菜单"; do case $choice in "显示所有活动 jail 的状态") print_info "正在获取状态..."; fail2ban-client status; press_enter_to_continue; break ;; "实时跟踪日志") print_info "正在实时跟踪日志 (按 Ctrl+C 停止)..."; tail -f /var/log/fail2ban.log; press_enter_to_continue; break ;; "返回主菜单") break ;; *) print_error "无效选项。" ;; esac; done; }
function view_banned_records() { clear; print_info "查看已封禁的 IP 记录"; echo "--------------------------------------------------"; local JAILS; JAILS=$(fail2ban-client status | grep "Jail list" | sed 's/.*Jail list:[ \t]*//' | sed 's/,//g'); if [[ -z "$JAILS" ]]; then print_warn "未找到任何活动的 jail。"; else print_info "找到以下活动的 jail，正在逐一显示其状态："; for jail in $JAILS; do echo ""; echo -e "${C_CYAN}--- Jail: [$jail] (项目) 的状态 ---${C_RESET}"; fail2ban-client status "$jail"; done; fi; press_enter_to_continue; }
function add_ssh_config() {
    clear; print_info "添加/更新 SSH 防护配置"; echo "--------------------------------------------------"; local UBUNTU_SSH_LOGPATH="/var/log/auth.log"; read -p "请输入 SSH 端口 [默认: 22]: " ssh_port; ssh_port=${ssh_port:-22}; read -p "请输入 SSH 日志路径 [Ubuntu 默认: $UBUNTU_SSH_LOGPATH]: " ssh_logpath; ssh_logpath=${ssh_logpath:-$UBUNTU_SSH_LOGPATH}; read -p "请输入封禁时长 (例如 1h, 1d) [默认: 1d]: " bantime; bantime=${bantime:-1d}; read -p "请输入最大重试次数 [默认: 3]: " maxretry; maxretry=${maxretry:-3}; read -p "请输入检测时间窗口 (例如 10m) [默认: 10m]: " findtime; findtime=${findtime:-10m};
    local CONFIG_FILE="/etc/fail2ban/jail.d/sshd.local"; local CONFIG_CONTENT="# 此文件由 fail2ban-manager-cn 脚本生成。\n[sshd]\nenabled = true\nport    = $ssh_port\nlogpath = $ssh_logpath\nbantime = $bantime\nmaxretry= $maxretry\nfindtime= $findtime"
    echo ""; print_info "以下配置将进行预检测试并应用:"; echo -e "${C_YELLOW}--------------------------------------------------"; echo -e "$CONFIG_CONTENT"; echo -e "--------------------------------------------------${C_RESET}"; echo ""; read -p "您确定要继续吗? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]*$ ]]; then test_and_apply_config "$CONFIG_CONTENT" "$CONFIG_FILE"; else print_warn "操作已取消。"; fi; press_enter_to_continue
}
function add_mysql_config() {
    clear; print_info "添加/更新 MySQL 防护配置"; echo "--------------------------------------------------"; local default_logpath="/var/log/mysql/error.log"; if [ -f /var/log/mariadb/mariadb.log ]; then default_logpath="/var/log/mariadb/mariadb.log"; fi
    read -p "请输入 MySQL 端口 [默认: 3306]: " mysql_port; mysql_port=${mysql_port:-3306}; read -p "请输入 MySQL 错误日志路径 [自动检测: $default_logpath]: " logpath; logpath=${logpath:-$default_logpath}
    if [ ! -f "$logpath" ]; then print_warn "日志文件 '$logpath' 不存在。"; read -p "是否要为此路径创建空日志文件以供 Fail2ban 监控? (Y/n): " create_log; if [[ "$create_log" =~ ^[Yy]*$ ]]; then mkdir -p "$(dirname "$logpath")" && touch "$logpath"; if [ $? -eq 0 ]; then print_success "已成功创建空日志文件: $logpath"; else print_error "创建日志文件失败，请检查权限。无法继续。"; press_enter_to_continue; return; fi; else print_warn "用户取消创建。预检将因找不到日志文件而失败。"; fi; fi
    read -p "请输入封禁时长 (例如 1h, 1d) [默认: 1h]: " bantime; bantime=${bantime:-1h}; read -p "请输入最大重试次数 [默认: 5]: " maxretry; maxretry=${maxretry:-5}; read -p "请输入检测时间窗口 (例如 10m) [默认: 10m]: " findtime; findtime=${findtime:-10m};
    local CONFIG_FILE="/etc/fail2ban/jail.d/mysqld-auth.local"; local CONFIG_CONTENT="# 此文件由 fail2ban-manager-cn 脚本生成。\n[mysqld-auth]\nenabled = true\nport    = $mysql_port\nlogpath = $logpath\nbantime = $bantime\nmaxretry= $maxretry\nfindtime= $findtime"
    echo ""; print_info "以下配置将进行预检测试并应用:"; echo -e "${C_YELLOW}--------------------------------------------------"; echo -e "$CONFIG_CONTENT"; echo -e "--------------------------------------------------${C_RESET}"; echo ""; read -p "您确定要继续吗? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]*$ ]]; then test_and_apply_config "$CONFIG_CONTENT" "$CONFIG_FILE"; else print_warn "操作已取消。"; fi; press_enter_to_continue
}
function manage_protection_config() { while true; do clear; echo -e "${C_CYAN}--- 添加/更新防护配置 ---${C_RESET}"; echo "1. SSH 防护"; echo "2. MySQL 防护"; echo "q. 返回主菜单"; echo "--------------------------"; read -p "请选择要配置的服务: " service_choice; case $service_choice in 1) add_ssh_config; break ;; 2) add_mysql_config; break ;; q|Q) break ;; *) print_error "无效选项，请重试。"; sleep 1 ;; esac; done; }
function remove_protection_config() {
    clear; print_info "移除防护配置"; echo "--------------------------------------------------"; local config_dir="/etc/fail2ban/jail.d"; local files=("$config_dir"/*.local)
    if [ ! -e "${files[0]}" ]; then print_warn "未在 $config_dir 中找到任何 .local 配置文件可供移除。"; press_enter_to_continue; return; fi
    print_info "请选择要移除的配置文件:"; select file_to_remove in "${files[@]}" "返回主菜单"; do
        if [[ "$file_to_remove" == "返回主菜单" ]]; then break; fi
        if [ -n "$file_to_remove" ]; then
            print_warn "即将永久删除配置文件: $file_to_remove"; read -p "您确定吗? (Y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]*$ ]]; then
                rm "$file_to_remove"; if [ $? -eq 0 ]; then print_success "文件 '$file_to_remove' 已删除。"; print_info "正在重新加载 Fail2ban 以应用更改..."; if fail2ban-client reload; then print_success "Fail2ban 重新加载成功。"; else print_error "重新加载失败，请检查日志。"; fi; else print_error "删除文件失败。"; fi
            else print_warn "操作已取消。"; fi; press_enter_to_continue; break
        else print_error "无效选项。"; fi
    done
}
function restore_config() { clear; print_info "从备份还原配置"; local backup_dir="/etc/fail2ban/backups"; echo "--------------------------------------------------"; if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir")" ]; then print_warn "未找到任何备份文件。备份会在您首次通过本脚本'添加/更新防护配置'时自动创建。"; press_enter_to_continue; return; fi; print_info "找到以下备份文件:"; local backups=("$backup_dir"/*.bak); select backup_file in "${backups[@]}" "返回主菜单"; do if [[ "$backup_file" == "返回主菜单" ]]; then break; fi; if [ -n "$backup_file" ]; then local original_filename=$(basename "$backup_file" | cut -d'.' -f1,2); local restore_path="/etc/fail2ban/jail.d/$original_filename"; print_warn "这将用 '$backup_file' 的内容覆盖 '$restore_path'。"; read -p "您确定要继续吗? (Y/n): " confirm; if [[ "$confirm" =~ ^[Yy]*$ ]]; then cp "$backup_file" "$restore_path"; print_success "已成功还原配置。"; print_info "正在重新加载 Fail2ban..."; if fail2ban-client reload; then print_success "重新加载成功。"; else print_error "重新加载失败，请检查日志。"; fi; else print_warn "操作已取消。"; fi; press_enter_to_continue; break; else print_error "无效选项。"; fi; done; }
function uninstall_fail2ban() { clear; print_warn "!!! 警告：即将完全卸载 Fail2ban !!!"; echo "--------------------------------------------------"; print_warn "此操作将："; echo "1. 停止并禁用 Fail2ban 服务。"; echo "2. 使用包管理器卸载 Fail2ban 程序。"; echo "3. 删除所有配置文件 (/etc/fail2ban 目录)。"; echo ""; read -p "您确定要继续吗? (y/N): " confirm1; if [[ ! "$confirm1" =~ ^[Yy]$ ]]; then print_info "卸载操作已取消。"; press_enter_to_continue; return; fi; echo ""; print_warn "最终确认：此操作不可逆！"; read -p "按 [Enter] 键立即执行卸载，输入任何字符再按回车则取消: " confirm2; if [[ -n "$confirm2" ]]; then print_info "检测到输入，卸载操作已取消。"; press_enter_to_continue; return; fi; print_info "正在执行卸载..."; sleep 1; print_info "正在停止并禁用服务..."; systemctl stop fail2ban &>/dev/null; systemctl disable fail2ban &>/dev/null; print_info "正在使用 apt 卸载并清除配置..."; apt-get purge -y fail2ban; print_success "Fail2ban 已被成功卸载。"; echo ""; read -p "按 [Enter] 键退出脚本..."; exit 0; }

# --- 脚本主入口 ---
initialize_environment
while true; do
    clear; echo -e "${C_CYAN}=============================================${C_RESET}"; echo -e "${C_CYAN}   Fail2ban 智能管理脚本 v8.0 (Ubuntu专用)   ${C_RESET}"; echo -e "${C_CYAN}=============================================${C_RESET}";
    echo "1. 查看状态和日志"; echo "2. 查看已封禁记录"; echo "3. 添加/更新防护配置"; echo -e "${C_YELLOW}4. 移除防护配置${C_RESET}"; echo "5. 从备份还原配置"; echo "6. 完全卸载 Fail2ban"; echo "q. 退出"; echo "---------------------------------------------"; read -p "请输入您的选择: " choice
    case $choice in 1) view_status_and_logs ;; 2) view_banned_records ;; 3) manage_protection_config ;; 4) remove_protection_config ;; 5) restore_config ;; 6) uninstall_fail2ban ;; q|Q) print_info "正在退出。"; exit 0 ;; *) print_error "无效选项，请重试。"; sleep 1 ;; esac
done
