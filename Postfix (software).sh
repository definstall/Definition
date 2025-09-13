#!/bin/bash

# PowerMTA 安装和管理脚本，仅支持 Ubuntu 系统
# 需要以 root 或 sudo 权限运行
# 优化交互式体验，自动生成 X.509 证书（CN=mail.example.com），下载并运行 cf_pmta

set -e  # 遇到错误时退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 打印状态信息的函数
print_status() {
    echo -e "${GREEN}[信息]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
    exit 1
}

# 检查是否以 root 权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行（使用 sudo）。"
        exit 1
    fi
}

# 检测 Ubuntu 系统
detect_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "无法检测操作系统，/etc/os-release 文件不存在。"
        exit 1
    fi
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        print_error "此脚本仅支持 Ubuntu 系统。检测到：$ID"
        exit 1
    fi
    print_status "检测到 Ubuntu 版本：$VERSION_ID"
}

# 检查 PowerMTA 服务状态
get_service_status() {
    if systemctl is-active --quiet pmta; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

# 生成 RSA 密钥对
generate_keys() {
    print_status "正在生成 RSA 密钥对..."
    mkdir -p /etc/pmta
    openssl genrsa -out /etc/pmta/pmta.key 2048 2>/dev/null
    openssl rsa -in /etc/pmta/pmta.key -pubout -out /etc/pmta/pmta.pem 2>/dev/null
    chmod 600 /etc/pmta/pmta.key /etc/pmta/pmta.pem
    print_status "密钥对已生成：/etc/pmta/pmta.key 和 /etc/pmta/pmta.pem"
}

# 停止并移除占用 25 端口的邮件服务器
remove_mail_servers() {
    print_status "检查并移除占用 25 端口的现有邮件服务器..."

    for service in postfix sendmail exim exim4; do
        if systemctl is-active --quiet $service; then
            print_warning "正在停止 $service..."
            systemctl stop $service
            systemctl disable $service
        fi
        if dpkg -l | grep -q "^ii  $service"; then
            print_status "正在移除 $service..."
            apt purge $service -y
        fi
    done

    if netstat -tlnp | grep -q ":25 "; then
        print_warning "正在杀死占用 25 端口的进程..."
        fuser -k 25/tcp 2>/dev/null || true
    fi

    print_status "25 端口现已空闲。"
}

# 安装依赖
install_deps() {
    print_status "更新软件包列表并安装依赖..."
    apt update
    apt install -y alien vim curl unzip net-tools openssl
}

# 运行 cf_pmta
run_cf_pmta() {
    local cf_file="/etc/pmta/cf_pmta"


    print_status "检查 cf_pmta 文件..."
    if [[ ! -f "$cf_file" ]]; then
        print_error "cf_pmta 文件不存在：$cf_file"
    fi
    if [[ ! -x "$cf_file" ]]; then
        print_warning "cf_pmta 文件不可执行，正在设置执行权限..."
        chmod 700 "$cf_file"
        chown root:root "$cf_file"
    fi

    print_status "正在运行 cf_pmta..."
    "$cf_file"
    if [ $? -ne 0 ]; then
        print_error "运行 cf_pmta 失败，请检查错误日志。"
    fi



read -p "手动保存IP和账户密码继续下一步？[Y/n]: " choice

# 将用户的输入转换为小写，方便判断
choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

# 使用 case 语句进行判断
case "$choice" in
    "n")
        echo "已选择退出。"
        exit 1
        ;;
    "y" | "")
        echo "继续执行下一步操作..."
        # 在这里添加你的后续命令
        echo "下一步操作已完成！"
        ;;
    *)
        echo "输入无效，默认继续。"
        echo "继续执行下一步操作..."
        # 在这里添加你的后续命令
        echo "下一步操作已完成！"
        ;;
esac


    print_status "cf_pmta 运行成功，配置文件已生成。"
}


# 下载并安装 PowerMTA 和 cf_pmta
install_powermta() {
    local download_url="https://www.dropbox.com/scl/fi/won4kyoidiflxbpxwelbl/PMTA.zip?rlkey=4e5iz4fnbc05p0izt3fah3nqa&st=04uftyj9&dl=0"
    local cf_download_url="https://www.dropbox.com/scl/fi/ytwlqqqf8hltamaysekkj/cf_pmta?rlkey=ylvxuhhd8fxbvosgahvr79052&st=om5zpr94&dl=0"
    local zip_file="PMTA.zip"
    local rpm_file="PowerMTA.rpm"
    local cf_file="/etc/pmta/cf_pmta"

    rm -rf license pmtad PowerMTA.rpm

    if [[ -d /etc/pmta && -f /etc/pmta/license ]]; then
        print_warning "PowerMTA 似乎已安装，检查证书和 cf_pmta..."
        if [[ ! -f /etc/pmta/pmta.pem || ! -f /etc/pmta/pmta.key ]]; then
            generate_keys
        fi
        if [[ ! -f /etc/pmta/cf_pmta ]]; then
            print_status "正在下载 cf_pmta..."
            curl -L -o "$cf_file" "$cf_download_url"
            if [ $? -ne 0 ]; then
                print_error "下载 cf_pmta 失败。"
            fi
            chmod 700 "$cf_file"
            chown root:root "$cf_file"
            print_status "正在运行 cf_pmta..."
            "$cf_file"
            if [ $? -ne 0 ]; then
                print_error "运行 cf_pmta 失败。"
            fi
        else
            print_status "cf_pmta 已存在，重新运行..."
            "$cf_file"
            if [ $? -ne 0 ]; then
                print_error "运行 cf_pmta 失败。"
            fi
        fi
        print_status "正在重启 PowerMTA 服务..."
        systemctl restart pmta || print_error "重启 PowerMTA 服务失败。"
        return
    fi

    print_status "正在下载 PMTA.zip..."
    curl -L -o "$zip_file" "$download_url"
    if [ $? -ne 0 ]; then
        print_error "下载 PMTA.zip 失败。"
    fi

    print_status "正在解压..."
    unzip "$zip_file"
    rm -f "$zip_file"

    if [[ ! -f "license" || ! -f "pmtad" || ! -f "$rpm_file" ]]; then
        print_error "下载的文件不完整：缺少 license、pmtad 或 $rpm_file。"
        exit 1
    fi

    print_status "使用 alien 安装 RPM..."
    alien -i "$rpm_file" --scripts
    if [ $? -ne 0 ]; then
        print_error "安装 PowerMTA RPM 失败。"
    fi

    print_status "复制 license 和 pmtad 文件..."
    mkdir -p /etc/pmta
    chmod 700 /etc/pmta
    chown root:root /etc/pmta
    cp license /etc/pmta/license
    cp pmtad /usr/sbin/pmtad

    # 生成证书
    generate_keys

    # 下载并运行 cf_pmta
    print_status "正在下载 cf_pmta..."
    curl -L -o "$cf_file" "$cf_download_url"
    if [ $? -ne 0 ]; then
        print_error "下载 cf_pmta 失败。"
    fi
    chmod 700 "$cf_file"
    chown root:root "$cf_file"
    print_status "正在运行 cf_pmta..."
    "$cf_file"
    if [ $? -ne 0 ]; then
        print_error "运行 cf_pmta 失败。"
    fi

    rm -f license pmtad "$rpm_file"


read -p "手动保存IP和账户密码继续下一步？[Y/n]: " choice

# 将用户的输入转换为小写，方便判断
choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

# 使用 case 语句进行判断
case "$choice" in
    "n")
        echo "已选择退出。"
        exit 1
        ;;
    "y" | "")
        echo "继续执行下一步操作..."
        # 在这里添加你的后续命令
        echo "下一步操作已完成！"
        ;;
    *)
        echo "输入无效，默认继续。"
        echo "继续执行下一步操作..."
        # 在这里添加你的后续命令
        echo "下一步操作已完成！"
        ;;
esac




    print_status "PowerMTA 安装完成。"

    # 启用并重启服务
    if systemctl is-enabled pmta >/dev/null 2>&1; then
        systemctl enable pmta
        print_status "正在重启 PowerMTA 服务..."
        systemctl restart pmta
        if [ $? -ne 0 ]; then
            print_error "重启 PowerMTA 服务失败。"
        fi
    else
        print_warning "PowerMTA 服务未配置 systemd 单元，请手动启用和启动。"
    fi
}

# 重新加载配置文件
reload_config() {
    print_status "正在重新加载 PowerMTA 配置文件..."
    systemctl reload pmta || print_warning "重新加载失败，服务可能未运行。"
}

# 重启服务
restart_service() {
    print_status "正在重启 PowerMTA..."
    systemctl restart pmta || print_error "重启 PowerMTA 服务失败。"
}

# 启动服务
start_service() {
    print_status "正在启动 PowerMTA..."
    systemctl start pmta || print_error "启动 PowerMTA 服务失败。"
}

# 停止服务
stop_service() {
    print_status "正在停止 PowerMTA..."
    systemctl stop pmta || print_warning "停止 PowerMTA 服务失败，服务可能已停止。"
}

# 检查服务状态
check_status() {
    print_status "PowerMTA 服务状态："
    systemctl status pmta || print_error "无法获取 PowerMTA 服务状态。"
}

# 分析日志文件
analyze_log() {
    local log_file="/var/log/pmta/acct.log"

    if [[ ! -f "$log_file" ]]; then
        print_error "日志文件 $log_file 不存在！"
        return 1
    fi

    print_status "正在分析所有域名的邮件发送数据..."

    domains=$(grep -oP "rcpt_domain=\K[^ ]+" "$log_file" | sort -u)

    if [ -z "$domains" ]; then
        print_error "日志文件中未找到任何域名！"
        return 1
    fi

    printf "\n%-30s %-15s %-15s %-15s %-15s\n" "域名" "成功发送" "总退信" "硬退信" "软退信"
    printf "%s\n" "-----------------------------------------------------------------------"

    while IFS= read -r domain; do
        success_count=$(grep "rcpt_domain=$domain" "$log_file" | grep "event=smtp" | wc -l)
        bounce_count=$(grep "rcpt_domain=$domain" "$log_file" | grep "event=bounce" | wc -l)
        hard_bounce_count=$(grep "rcpt_domain=$domain" "$log_file" | grep "event=bounce" | grep "dsn=5" | wc -l)
        soft_bounce_count=$(grep "rcpt_domain=$domain" "$log_file" | grep "event=bounce" | grep "dsn=4" | wc -l)
        printf "%-30s %-15s %-15s %-15s %-15s\n" "$domain" "$success_count" "$bounce_count" "$hard_bounce_count" "$soft_bounce_count"
    done <<< "$domains"

    print_status "日志分析完成。"
}

# 卸载 PowerMTA
uninstall_powermta() {
    print_warning "正在卸载 PowerMTA..."

    stop_service

    systemctl disable pmta 2>/dev/null || true
    rm -f /etc/systemd/system/pmta.service 2>/dev/null || true
    systemctl daemon-reload

    rm -rf /etc/pmta
    rm -f /usr/sbin/pmtad

    dpkg -l | grep -q power || true
    apt purge power* -y 2>/dev/null || true

    print_status "PowerMTA 已卸载。"
}

# 交互式菜单
show_menu() {
    clear
    local service_status
    service_status=$(get_service_status)
    echo ""
    echo "=== PowerMTA 管理菜单 ==="
    echo "当前 PowerMTA 服务状态：$service_status"
    echo "1. 安装 PowerMTA（包括依赖、移除邮件服务器、下载 cf_pmta、生成证书）"
    echo "2. 运行 Cloudflera配置"
    echo "3. 重启服务"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 检查服务状态"
    echo "7. 分析日志文件"
    echo "8. 卸载 PowerMTA"
    echo "9. 重新加载配置文件"
    echo "0. 退出"
    echo ""
    read -p "请选择一个选项： " choice
    clear
    case $choice in
        1) remove_mail_servers; install_deps; install_powermta ;;
        2) run_cf_pmta ;;
        3) restart_service ;;
        4) start_service ;;
        5) stop_service ;;
        6) check_status ;;
        7) analyze_log ;;
        8) uninstall_powermta ;;
        9) reload_config ;;
        0) exit 0 ;;
        *) print_error "无效选项，请重试。" ;;
    esac
}

# 主程序
main() {
    check_root
    detect_ubuntu

    while true; do
        show_menu
    done
}

# 如果脚本直接运行，调用主程序
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
