#!/bin/bash

# cf.sh - Postfix 安装、调试和管理脚本（修复版）
# 基于 Debian/Ubuntu 系统（使用 apt）。
# 运行前请确保你拥有 root 权限：sudo ./postfix_2.sh

set -e
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 核心变量定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/root/Postfix_logs"
TEMP_RESPONSE_FILE="$LOG_DIR/cloudflare_api_response.txt"
LOG_FILE="$LOG_DIR/Postfix_install.log"
INSTALL_LOG="$LOG_DIR/apt_install_temp.log"
CONFIG_FILE="$SCRIPT_DIR/PostFix_Cloudflare.conf"
USE_JQ=true
CLOUDFLARE_EMAIL=""
CLOUDFLARE_API_KEY=""
DOMAIN=""
ZONE_ID=""
EXTERNAL_IP=""
MAIN_DOMAIN=""
SMTP_USER=""
SMTP_PASS=""
DKIM_SELECTOR=""
OS_FAMILY="" # 新增：用于存储检测到的操作系统家族
CERT_DIR="/etc/postfix/ssl"
CERT_FILE="$CERT_DIR/smtpd.crt"
KEY_FILE="$CERT_DIR/smtpd.key"
POSTFIX_TARGET_VERSION="3.10" # 目标安装版本系列
POSTFIX_SASLAUTHD_RUN_DIR="/var/spool/postfix/var/run/saslauthd"



# 初始化日志目录
init_logs() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE" "$INSTALL_LOG"
    : > "$TEMP_RESPONSE_FILE" || true
    chmod 644 "$LOG_FILE" "$INSTALL_LOG"
}

detect_os() {
    print_status "正在检测操作系统..."

    # 优先检查 /etc/os-release 文件
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        # $ID 变量在 os-release 中定义 (如 debian 或 ubuntu)
        case "$ID" in
            debian)
                OS_FAMILY="debian"
                ;;
            ubuntu)
                OS_FAMILY="ubuntu"
                ;;
            *)
                OS_FAMILY="other"
                print_warning "检测到非 Debian/Ubuntu 系统 ($ID)，脚本兼容性可能存在问题。"
                exit 1
                ;;
        esac
    else
        # 备用检测方法 (例如使用 lsb_release)
        if command -v lsb_release >/dev/null 2>&1 && lsb_release -is | grep -qi "ubuntu"; then
             OS_FAMILY="ubuntu"
             #-------------防火墙
             ufw allow 587/tcp
             ufw allow 465/tcp
             ufw allow 22/tcp
             ufw disable
             ufw enable
        elif command -v lsb_release >/dev/null 2>&1 && lsb_release -is | grep -qi "debian"; then
            OS_FAMILY="debian"
             #-------------防火墙
            iptables -A INPUT -p tcp --dport 465 -j ACCEPT
            iptables -A INPUT -p tcp --dport 587 -j ACCEPT
            iptables -A INPUT -p tcp --dport 22 -j ACCEPT
            netfilter-persistent reload
        else
             OS_FAMILY="unknown"
             print_warning "无法检测操作系统类型，脚本兼容性可能存在问题。"
             exit 1
             #OS_FAMILY="debian" # 默认值
        fi
    fi
    print_status "当前操作系统家族：$OS_FAMILY" true
}

# print helpers
print_status() {
    local message="$1"
    local silent_mode="${2:-false}"
    if [ "$silent_mode" = "false" ]; then
        echo -e "${GREEN}[信息]${NC} $message" >&2
    fi
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') $message" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1" >&2
    echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

show_header() {
    echo -e "${YELLOW}====================================================${NC}"
    echo -e "${BLUE}🚀 Postfix 邮件服务器管理脚本（修复版）${NC}"
    echo -e "${YELLOW}----------------------------------------------------${NC}"
    echo -e " 域名: ${GREEN}${DOMAIN:-未设置} | IP: ${GREEN}${EXTERNAL_IP:-未设置}${NC}"
    echo -e "${YELLOW}====================================================${NC}"
}

# Spinner function (进度指示器)
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\\'
    printf "\r" >&2
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r${YELLOW}[进度] ${NC}[%c] " "$spinstr" >&2
        spinstr=$temp${spinstr:0:1}
        sleep $delay
    done
    printf "\r" >&2
}

# JSON parser checker (优先 jq，否则 python3)
check_json_parser() {
    if command -v jq >/dev/null 2>&1; then
        print_status "检测到 jq，将优先使用 jq 解析 JSON。" true
        USE_JQ=true
    elif command -v python3 >/dev/null 2>&1; then
        print_warning "未检测到 jq，将使用 Python 解析 JSON。"
        USE_JQ=false
    else
        print_status "未找到 jq，正在尝试安装..." true
        apt-get update -y &> /dev/null || true
        apt-get install -y jq &>> "$INSTALL_LOG" || true
        if command -v jq >/dev/null 2>&1; then
            print_status "jq 已成功安装。" true
            USE_JQ=true
        elif command -v python3 >/dev/null 2>&1; then
            print_warning "未能安装 jq，但检测到 python3，改用 python3 解析 JSON。"
            USE_JQ=false
        else
            print_error "无法找到 jq 或 python3，请手动安装。"
            exit 1
        fi
    fi
}

validate_variable() {
    local var_name="$1"
    local var_value="$2"
    if [[ "$var_value" == *\'* || "$var_value" == *\"* || "$var_value" == *\;* ]]; then
        print_error "$var_name 包含非法字符（单引号、双引号或分号）：$var_value"
        exit 1
    fi
}

# Cloudflare API wrapper (写入 TEMP_RESPONSE_FILE 并返回 body)
cloudflare_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    : > "$TEMP_RESPONSE_FILE"
    : > "$LOG_DIR/cloudflare_http_code.txt"

    local curl_cmd=(curl -s -X "$method" "https://api.cloudflare.com/client/v4/$endpoint" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        -H "Content-Type: application/json")

    if [ -n "$data" ]; then
        curl_cmd+=(--data-raw "$data")
    fi

    print_status "执行 Cloudflare API: $method $endpoint" true
    if [ -n "$data" ]; then
        print_status "请求数据: ${data:0:200}..." true
    fi

    # 捕获 HTTP 状态码并写入文件
    "${curl_cmd[@]}" -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" > "$LOG_DIR/cloudflare_http_code.txt" 2>>"$LOG_FILE" || true
    local http_code
    http_code=$(cat "$LOG_DIR/cloudflare_http_code.txt" 2>/dev/null || echo "")
    local response
    response=$(cat "$TEMP_RESPONSE_FILE" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        print_error "Cloudflare API 无响应（HTTP: $http_code）。请检查网络或 API 凭证。完整响应保存在 $TEMP_RESPONSE_FILE"
        exit 1
    fi

    if [ "$http_code" -ge 400 ]; then
        print_error "Cloudflare API 返回 HTTP 错误: $http_code"
        if [ "$USE_JQ" = true ]; then
            error_msg=$(echo "$response" | jq -r '.errors[0].message // "未知错误"') || error_msg="未知错误"
            error_code=$(echo "$response" | jq -r '.errors[0].code // "无错误代码"') || error_code="无错误代码"
        else
            error_msg=$(python3 - <<PY - 2>/dev/null
import json,sys
try:
    d=json.loads(open("$TEMP_RESPONSE_FILE").read())
    print(d.get('errors',[{}])[0].get('message','未知错误'))
except Exception as e:
    print('未知错误')
PY
)
            error_code=$(python3 - <<PY - 2>/dev/null
import json,sys
try:
    d=json.loads(open("$TEMP_RESPONSE_FILE").read())
    print(d.get('errors',[{}])[0].get('code','无错误代码'))
except Exception as e:
    print('无错误代码')
PY
)
        fi
        print_error "Cloudflare 错误详情: 代码 $error_code, 消息 $error_msg"
        print_error "完整响应已写入 $TEMP_RESPONSE_FILE"
        exit 1
    fi

    echo "$response"
}

# 获取外网 IP
get_external_ip() {
    print_status "正在获取外网 IP 地址..."
    EXTERNAL_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "")
    if [ -z "$EXTERNAL_IP" ]; then
        print_error "无法获取外网 IP 地址"
        exit 1
    fi
    validate_variable "EXTERNAL_IP" "$EXTERNAL_IP"
    print_status "外网 IP：$EXTERNAL_IP" true
}

# 获取 Cloudflare Zone ID（保留你原逻辑，使用 cloudflare_api）
get_zone_id() {
    print_status "获取 Cloudflare 区域 ID..."
    local zones_response
    zones_response=$(cloudflare_api GET zones)

    local parts
    IFS='.' read -r -a parts <<< "$DOMAIN"
    local parent=""
    if [ ${#parts[@]} -ge 2 ]; then
        parent="${parts[-2]}.${parts[-1]}"
    fi
    validate_variable "parent" "$parent"

    local zone_id_candidate=""
    if [ -n "$parent" ]; then
        if [ "$USE_JQ" = true ]; then
            zone_id_candidate=$(echo "$zones_response" | jq -r --arg d "$parent" '.result[] | select(.name == $d) | .id' 2>/dev/null || echo "")
        else
            zone_id_candidate=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
for r in d.get('result',[]):
    if r.get('name')==os.environ.get('PARENT'):
        print(r.get('id'))
        break
PY
)
        fi
    fi

    if [ -z "$zone_id_candidate" ]; then
        if [ "$USE_JQ" = true ]; then
            zone_id_candidate=$(echo "$zones_response" | jq -r --arg d "$DOMAIN" '.result[] | select(.name == $d) | .id' 2>/dev/null || echo "")
        else
            zone_id_candidate=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
for r in d.get('result',[]):
    if r.get('name')==os.environ.get('DOMAIN'):
        print(r.get('id'))
        break
PY
)
            MAIN_DOMAIN="$DOMAIN"
        fi
    fi

    if [ -z "$zone_id_candidate" ]; then
        print_error "未找到匹配的 Cloudflare 区域。请检查您的域名和 Cloudflare 账户。"
        exit 1
    fi

    ZONE_ID="$zone_id_candidate"
    # 如果 MAIN_DOMAIN 未被设置，尝试设置
    if [ -z "$MAIN_DOMAIN" ]; then
        MAIN_DOMAIN="$parent"
    fi
    print_status "找到区域：$MAIN_DOMAIN，ID：$ZONE_ID" true
}

# 在 Cloudflare 中添加/更新 A, MX, SPF, DMARC 记录（保持原逻辑）
add_dns_records() {
    local json_data response record_id record_name
    if [ "$DOMAIN" = "$MAIN_DOMAIN" ] || [ -z "$MAIN_DOMAIN" ]; then
        record_name="@"
    else
        record_name="${DOMAIN%.$MAIN_DOMAIN}"
    fi

    print_status "开始处理 DNS 记录..."

    # A 记录
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=A")
    if [ "$USE_JQ" = true ]; then
        record_id=$(echo "$response" | jq -r '.result[0].id // ""' 2>/dev/null || echo "")
    else
        record_id=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
if d.get('result'):
    print(d['result'][0].get('id',''))
PY
)
    fi
    json_data=$(jq -n --arg name "$DOMAIN" --arg ip "$EXTERNAL_IP" '{type: "A", name: $name, content: $ip, ttl: 120, proxied: false}')
    if [ -n "$record_id" ]; then
        print_status "更新 A 记录: $DOMAIN -> $EXTERNAL_IP" true
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data" >/dev/null
    else
        print_status "创建 A 记录: $DOMAIN -> $EXTERNAL_IP" true
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data" >/dev/null
    fi

    # MX 记录
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=MX")
    if [ "$USE_JQ" = true ]; then
        record_id=$(echo "$response" | jq -r --arg mx "$DOMAIN" '.result[] | select(.content == $mx) | .id // ""' 2>/dev/null || echo "")
    else
        record_id=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
for r in d.get('result',[]):
    if r.get('content')==os.environ.get('MX'):
        print(r.get('id'))
        break
PY
)
    fi
    json_data=$(jq -n --arg name "$record_name" --arg mx "$DOMAIN" '{type: "MX", name: $name, content: $mx, priority: 10, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "更新 MX 记录: $DOMAIN -> $DOMAIN" true
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data" >/dev/null
    else
        print_status "创建 MX 记录: $DOMAIN -> $DOMAIN" true
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data" >/dev/null
    fi

    # SPF TXT
    local spf_value="v=spf1 a mx ip4:$EXTERNAL_IP ~all"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=TXT")
    if [ "$USE_JQ" = true ]; then
        record_id=$(echo "$response" | jq -r --arg spf "$spf_value" '.result[] | select(.content == $spf) | .id // ""' 2>/dev/null || echo "")
    else
        record_id=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
for r in d.get('result',[]):
    if r.get('content')==os.environ.get('SPF'):
        print(r.get('id'))
        break
PY
)
    fi
    json_data=$(jq -n --arg name "$record_name" --arg spf "$spf_value" '{type: "TXT", name: $name, content: $spf, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "更新 SPF 记录: $spf_value" true
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data" >/dev/null
    else
        print_status "创建 SPF 记录: $spf_value" true
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data" >/dev/null
    fi

    # DMARC
    local dmarc_value="v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=_dmarc.$DOMAIN&type=TXT")
    if [ "$USE_JQ" = true ]; then
        record_id=$(echo "$response" | jq -r --arg dmarc "$dmarc_value" '.result[] | select(.content == $dmarc) | .id // ""' 2>/dev/null || echo "")
    else
        record_id=$(python3 - <<PY - 2>/dev/null
import json,os
d=json.loads(open(os.environ['TEMP_RESPONSE_FILE']).read())
for r in d.get('result',[]):
    if r.get('content')==os.environ.get('DMARC'):
        print(r.get('id'))
        break
PY
)
    fi
    json_data=$(jq -n --arg name "_dmarc.$DOMAIN" --arg dmarc "$dmarc_value" '{type: "TXT", name: $name, content: $dmarc, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "更新 DMARC 记录: $dmarc_value" true
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data" >/dev/null
    else
        print_status "创建 DMARC 记录: $dmarc_value" true
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data" >/dev/null
    fi

    print_status "DNS 记录处理完成！"
}

check_system() {
    print_status "正在执行系统环境检查..."
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 身份运行！"
        exit 1
    fi

    ulimit -n 102400 &> /dev/null || true
    print_status "ulimit -n 已设置为 102400。" true

    if ss -tln | grep -q ':25'; then
        print_warning "检测到 25 端口正在被占用。请确认是 Postfix 或其他邮件系统在使用。"
    else
        print_status "25 端口未被占用。" true
    fi

    print_status "检查其他邮件系统..."
    if dpkg -s exim4 >/dev/null 2>&1 || dpkg -s sendmail >/dev/null 2>&1; then
        print_warning "检测到其他邮件系统（exim4 或 sendmail）。"
        read -p "是否卸载这些系统？(y/n) [Y]: " confirm
        confirm=${confirm:-y}
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            print_status "正在卸载 exim4 和 sendmail..."
            apt-get purge -y exim4 sendmail &> /dev/null || true
            apt-get autoremove -y &> /dev/null || true
            print_status "其他邮件系统已卸载。"
        else
            print_status "已取消卸载。"
        fi
    else
        print_status "未检测到其他邮件系统。" true
    fi

    # 修复 dpkg 中断状态
    if ! dpkg --configure -a &> /dev/null; then
        print_warning "尝试修复 dpkg 配置..."
        dpkg --configure -a &> /dev/null || true
    fi
}

uninstall_all() {
    print_status "正在停止并卸载所有邮件相关组件..."
    service postfix stop || true
    service opendkim stop || true
    service saslauthd stop || true

    {
        apt-get purge -y postfix opendkim opendkim-tools postfix-policyd-spf-python sasl2-bin libsasl2-modules &>> "$INSTALL_LOG" || true
    } &> /dev/null &

    local purge_pid=$!
    printf "${YELLOW}  正在执行组件清理...${NC}" >&2
    spinner $purge_pid

    if ! wait $purge_pid; then
        print_warning "组件卸载可能遇到错误（请检查 $INSTALL_LOG）。"
    else
        printf "${GREEN}[完成] ${NC}组件清理完成。\n" >&2
    fi

    apt-get autoremove -y &>> "$INSTALL_LOG" || true
    rm -rf /etc/dkimkeys || true
    rm -rf "$CERT_DIR" || true
    print_status "所有邮件相关组件已成功卸载。"
}

generate_self_signed_cert() {
    print_status "正在生成自签名 SSL/TLS 证书..."

    mkdir -p "$CERT_DIR"
    service postfix stop || true

    openssl genrsa -out "$KEY_FILE" 2048 &>> "$LOG_FILE" || true
    openssl req -new -key "$KEY_FILE" -out "$CERT_DIR/smtpd.csr" -subj "/C=US/ST=State/L=City/O=Self-Signed/CN=$DOMAIN" &>> "$LOG_FILE" || true
    openssl x509 -req -days 365 -in "$CERT_DIR/smtpd.csr" -signkey "$KEY_FILE" -out "$CERT_FILE" &>> "$LOG_FILE" || true

    chmod 600 "$KEY_FILE" || true
    chmod 644 "$CERT_FILE" || true
    print_status "自签名证书已成功生成。" true
    service postfix start || true
}

# ---------- 修复点：使用 postconf 安全修改 main.cf，并可靠写入 master.cf ----------
configure_postfix() {
    print_status "正在配置 Postfix main.cf（使用 postconf 安全修改）..."
    # 备份 current files
    [ -f /etc/postfix/main.cf ] && cp /etc/postfix/main.cf /etc/postfix/main.cf.bak || true
    [ -f /etc/postfix/master.cf ] && cp /etc/postfix/master.cf /etc/postfix/master.cf.bak || true

    # 使用 postconf -e 来设置配置项（避免直接覆盖 entire main.cf 的风险）
    postconf -e "myhostname = $DOMAIN"
    postconf -e "mydomain = $DOMAIN"
    postconf -e "myorigin = \$mydomain"
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = all"

    # NOTE: 队列快速膨胀，消耗磁盘空间（/var/spool/postfix）；若磁盘满，会导致邮件无法写入或服务异常。
    postconf -e "default_process_limit = 500"
    #含义：Postfix 允许的最大子进程总数（整体并发上限）。
    postconf -e "default_destination_concurrency_limit = 500"
    #含义：对默认目的地允许的并发投递连接数上限（每个目的主机/域）。
    postconf -e "initial_destination_concurrency = 30"
    #含义：首次投递时的并发初始值，Postfix 会动态调整
    postconf -e "smtp_destination_concurrency_limit = 5000"
    #含义：对每个目的地主机并发发起的投递连接数上限。限制对单个远端的发信并发。
    postconf -e "smtpd_client_connection_limit = 5000"
    # 含义：单个客户端 IP 可打开的并发 smtpd 连接数上限（防止某个 IP 同时打开大量连接）

    # NOTE: 这些 backoff/queue 设置在原脚本为 1s（极短），保留但建议在生产中改为合理值
    postconf -e "smtp_destination_rate_delay = 1s"
    #含义：向同一目的地主机连续发送邮件时每连接之间的最小延迟（用于限速）。`1s` 表示每连接间隔 1 秒。
    postconf -e "minimal_backoff_time = 30s"
    postconf -e "maximal_backoff_time = 60s"
    postconf -e "maximal_queue_lifetime = 1000s"

    ## 本地/虚拟收件与中继
    postconf -e "mydestination = \$myhostname, localhost, \$mydomain, $DOMAIN"
    postconf -e "local_recipient_maps = unix:passwd.byname \$virtual_alias_maps"
    postconf -e "virtual_alias_domains = $DOMAIN"
    postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"
    postconf -e "relay_domains ="
    #  - 含义：Postfix 接受并转发（中继）的域列表。为空表示不对外中继，这是常见且安全的设置（避免开放中继）。
    postconf -e "relayhost ="
    #  - 含义：如果设置，为所有外发邮件指定上游 smarthost（例如 ISP 或外部 SMTP 中继）。空表示直接按目标 MX 投递。
    postconf -e "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 $EXTERNAL_IP/32"
    postconf -e "mailbox_size_limit = 5000000"
    # 限制的是“邮箱总容量”，当本地投递发现超过该值会拒绝/产生 552 这里50MB
    postconf -e "message_size_limit = 2048576"
    # 限制单封大小 2MB
    postconf -e "recipient_delimiter = +"
    postconf -e "home_mailbox = EmailBox"
    #原先的  Maildir

    # TLS 相关
    postconf -e "smtpd_use_tls = yes"
    postconf -e "smtpd_tls_cert_file = $CERT_FILE"
    postconf -e "smtpd_tls_key_file = $KEY_FILE"

    # 明确禁用老旧 TLS 协议，提高与现代客户端兼容性
    postconf -e "smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1"
    postconf -e "smtpd_tls_security_level = may"
    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtpd_tls_loglevel = 1"
    postconf -e "smtpd_tls_received_header = yes"

    # SASL / Authentication
    postconf -e "smtpd_sasl_auth_enable = yes"
    postconf -e "smtpd_sasl_type = cyrus"
    postconf -e "smtpd_sasl_path = smtpd"
    postconf -e "smtpd_sasl_security_options = noanonymous"
    postconf -e "broken_sasl_auth_clients = yes"

    # Recipient restrictions (顺序重要)
    postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, check_policy_service unix:private/policy-spf"

    # Milter
    postconf -e "milter_default_action = accept"
    postconf -e "milter_protocol = 2"
    postconf -e "smtpd_milters = inet:localhost:8891"
    postconf -e "non_smtpd_milters = inet:localhost:8891"

    # header_checks
    cat > /etc/postfix/header_checks <<EOF
/^Received: from.*/ IGNORE
EOF
    # 对于 regexp 不需要 postmap

    print_status "正在更新 master.cf（删除旧的 submission/smtps 段后追加标准段）..."
    # 删除以 submission 或 smtps 开头的旧段（避免重复）
    sed -i '/^submission[[:space:]]/d; /^smtps[[:space:]]/d' /etc/postfix/master.cf

    # 追加标准可靠的 submission/smtps 段（使用 'MASTER_EOF' 以防变量展开）
    cat >> /etc/postfix/master.cf <<'MASTER_EOF'

submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject

smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_sasl_security_options=noanonymous
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject

# 确保 25 端口( smtp ) 默认不要求 auth，但允许 opportunistic TLS
smtp      inet  n       -       y       -       -       smtpd
  -o smtpd_sasl_auth_enable=no
  -o smtpd_tls_security_level=may

MASTER_EOF

    print_status "Postfix main.cf 与 master.cf 配置已完成。"
}

configure_policyd() {
    print_status "正在配置 Postfix Policyd (postfix-policyd-spf-python)..."
    if ! grep -q "policy-spf" /etc/postfix/master.cf 2>/dev/null; then
        print_status "添加 policy-spf 配置到 master.cf..." true
        echo "policy-spf unix - n n - - spawn user=policyd-spf argv=/usr/bin/policyd-spf" >> /etc/postfix/master.cf
    else
        print_status "master.cf 已包含 policy-spf 配置。" true
    fi
    print_status "Postfix Policyd 配置完成。" true
}

configure_sasl() {
    print_status "正在配置 SASL 认证..."
    mkdir -p /etc/postfix/sasl

    print_status "写入 /etc/postfix/sasl/smtpd.conf ..."
    cat > /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: saslauthd
mech_list: plain login
EOF

    # 创建 SMTP 认证账户（如未创建则创建）
    print_status "创建 SMTP 认证账户：$SMTP_USER@$DOMAIN ..."
    # 确保 saslauthd 服务在执行 saslpasswd2 之前停止，以避免文件锁定冲突
    systemctl stop saslauthd.service 2>/dev/null || service saslauthd stop 2>/dev/null || true
    echo "$SMTP_PASS" | saslpasswd2 -c -u "$DOMAIN" "$SMTP_USER" &>> "$LOG_FILE" || true

    # 如果使用 sasldb 存储，修正 sasldb 文件权限并加入 postfix 到 sasl 组
    if [ -f /etc/sasldb2 ]; then
        chown root:sasl /etc/sasldb2 || true
        chmod 0640 /etc/sasldb2 || true
        if getent group sasl >/dev/null 2>&1; then
            if ! id -nG postfix 2>/dev/null | grep -qw sasl; then
                adduser postfix sasl >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 修正 /etc/default/saslauthd，使用宿主机 socket 目录（不使用 chroot 的 PIDFile 覆盖）
    if [ -f "/etc/default/saslauthd" ]; then
        print_status "配置 /etc/default/saslauthd，使用宿主机 socket 目录 /var/run/saslauthd ..."
        # 备份一次（幂等）
        cp /etc/default/saslauthd /etc/default/saslauthd.bak 2>/dev/null || true

        sed -i 's/^MECHANISMS=.*/MECHANISMS="sasldb"/' /etc/default/saslauthd || true
        sed -i 's/^START=.*/START=yes/' /etc/default/saslauthd || true
        # 删除可能存在的 SOCKETDIR/OPTIONS 旧行
        sed -i '/^SOCKETDIR=/d' /etc/default/saslauthd || true
        sed -i '/^OPTIONS=/d' /etc/default/saslauthd || true

        # 写入 OPTIONS 指向宿主机 /var/run/saslauthd（不使用 -c，以便 systemd 的默认行为正常）
        if ! grep -q -- 'OPTIONS=".*-m /var/run/saslauthd' /etc/default/saslauthd 2>/dev/null; then
            echo 'OPTIONS="-m /var/run/saslauthd -n 5"' >> /etc/default/saslauthd || true
        fi
        if ! grep -q '^START=' /etc/default/saslauthd 2>/dev/null; then
            echo 'START=yes' >> /etc/default/saslauthd || true
        fi
    else
        print_warning "/etc/default/saslauthd 文件不存在，创建一个默认配置..."
        cat >/etc/default/saslauthd <<EOF
START=yes
MECHANISMS="sasldb"
OPTIONS="-m /var/run/saslauthd -n 5"
EOF
    fi

    # 确保宿主机 socket 目录存在并权限正确
    print_status "确保宿主机 saslauthd socket 目录 /var/run/saslauthd 存在并设置权限..."
    mkdir -p /var/run/saslauthd
    chown root:sasl /var/run/saslauthd 2>/dev/null || true
    chmod 0755 /var/run/saslauthd 2>/dev/null || true

    # 创建 Postfix chroot 下的目录（将通过 bind-mount 挂载宿主机 socket）
    print_status "创建 Postfix chroot 下的 socket 目录：$POSTFIX_SASLAUTHD_RUN_DIR"
    mkdir -p "$POSTFIX_SASLAUTHD_RUN_DIR"
    chown root:root "$POSTFIX_SASLAUTHD_RUN_DIR" 2>/dev/null || true
    chmod 0755 "$POSTFIX_SASLAUTHD_RUN_DIR" 2>/dev/null || true

    # 将 /var/run/saslauthd bind-mount 到 /var/spool/postfix/var/run/saslauthd，持久化到 /etc/fstab（如果尚未配置）
    FSTAB_LINE="/var/run/saslauthd $POSTFIX_SASLAUTHD_RUN_DIR none bind 0 0"
    if ! grep -Fq "$FSTAB_LINE" /etc/fstab 2>/dev/null; then
        print_status "向 /etc/fstab 添加 bind 挂载条目（保证重启后 chroot 可见）..."
        echo "$FSTAB_LINE" >> /etc/fstab || true
    fi
    # 立即生效（幂等）
    if ! mountpoint -q "$POSTFIX_SASLAUTHD_RUN_DIR"; then
        mount --bind /var/run/saslauthd "$POSTFIX_SASLAUTHD_RUN_DIR" 2>/dev/null || true
    fi

    # 删除之前可能写入的错误 override（PIDFile 指向 chroot 会导致 systemd 挂起）
    if [ -f /etc/systemd/system/saslauthd.service.d/override.conf ]; then
        # 备份后删除
        cp /etc/systemd/system/saslauthd.service.d/override.conf /root/override.saslauthd.conf.bak 2>/dev/null || true
        rm -f /etc/systemd/system/saslauthd.service.d/override.conf || true
    fi

    # -------------------------------------------------------------------------
    # 修复点：为 saslauthd 创建 Systemd drop-in，确保启动顺序和 PID 文件正确
    # -------------------------------------------------------------------------
    print_status "为 saslauthd 创建 Systemd drop-in 配置文件..."
    mkdir -p /etc/systemd/system/saslauthd.service.d >/dev/null 2>&1 || true

    # 使用 local_override.conf 避免与默认 override.conf 冲突，并强化依赖
    cat >/etc/systemd/system/saslauthd.service.d/local_override.conf <<'EOF'
[Unit]
# 确保在网络目标和本地文件系统准备好后启动（包括 /etc/fstab 挂载）
Wants=network-online.target local-fs.target
After=network-online.target local-fs.target

[Service]
# 使用 /var/run/saslauthd/saslauthd.pid 作为 PID 文件
PIDFile=/var/run/saslauthd/saslauthd.pid
Type=forking
# 启动前确保 socket 目录存在且权限正确
ExecStartPre=-/bin/mkdir -p /var/run/saslauthd
ExecStartPre=-/bin/chown root:sasl /var/run/saslauthd
ExecStartPre=-/bin/chmod 0755 /var/run/saslauthd
# 确保在 /etc/default/saslauthd 中配置了 OPTIONS="-m /var/run/saslauthd..."
EOF
    # -------------------------------------------------------------------------

    # 重新加载 systemd（确保移除错误 override 并加载新的 local_override）
    systemctl daemon-reload || true
    print_status "systemd 重载已完成，saslauthd 依赖已强化。"

    # 启用并启动 saslauthd（幂等）
    print_status "启用并启动 saslauthd 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable saslauthd.service >/dev/null 2>&1 || true
        systemctl restart saslauthd.service >/dev/null 2>&1 || systemctl start saslauthd.service >/dev/null 2>&1 || true
    else
        update-rc.d saslauthd defaults >/dev/null 2>&1 || true
        service saslauthd restart >/dev/null 2>&1 || service saslauthd start >/dev/null 2>&1 || true
    fi

    # 确保 postfix 用户可以访问 socket（group membership）
    if getent group sasl >/dev/null 2>&1; then
        if ! id -nG postfix 2>/dev/null | grep -qw sasl; then
            adduser postfix sasl >/dev/null 2>&1 || true
        fi
    fi

    # 创建 postfix 的 systemd drop-in，确保 postfix 在 saslauthd 启动后再启动（幂等）
    mkdir -p /etc/systemd/system/postfix.service.d >/dev/null 2>&1 || true
    cat >/etc/systemd/system/postfix.service.d/override.conf <<'EOF'
[Unit]
Wants=saslauthd.service
After=saslauthd.service
EOF

    # 重新加载 systemd 并启用 & 重启 postfix 以使依赖生效
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable postfix.service >/dev/null 2>&1 || true
    # 这里只做 enable 和 daemon-reload，实际重启在 install_postfix 结尾的 restart_all_services 中完成
    # systemctl restart postfix.service >/dev/null 2>&1 || service postfix restart >/dev/null 2>&1 || true

    print_status "检查 Postfix 虚拟别名映射文件..."
    if [ ! -f /etc/postfix/virtual ]; then
        print_status "创建空文件 /etc/postfix/virtual ..."
        touch /etc/postfix/virtual || print_error "无法创建 /etc/postfix/virtual"
    else
        print_status "/etc/postfix/virtual 已存在，跳过创建"
    fi
}

configure_opendkim() {
    print_status "配置 OpenDKIM..."
    mkdir -p /etc/opendkim
    chown -R opendkim:opendkim /etc/opendkim || true

    mkdir -p /etc/dkimkeys/"$MAIN_DOMAIN" || true
    echo "$DKIM_SELECTOR._domainkey.$MAIN_DOMAIN $MAIN_DOMAIN:$DKIM_SELECTOR:/etc/dkimkeys/$MAIN_DOMAIN/$DKIM_SELECTOR.private" > /etc/opendkim/KeyTable || true
    chmod 644 /etc/opendkim/KeyTable || true

    echo "*@$MAIN_DOMAIN $DKIM_SELECTOR._domainkey.$MAIN_DOMAIN" > /etc/opendkim/SigningTable || true
    echo "*@$DOMAIN $DKIM_SELECTOR._domainkey.$MAIN_DOMAIN" >> /etc/opendkim/SigningTable || true
    chmod 644 /etc/opendkim/SigningTable || true

    echo "127.0.0.1" > /etc/opendkim/TrustedHosts || true
    echo "localhost" >> /etc/opendkim/TrustedHosts || true
    echo "$EXTERNAL_IP" >> /etc/opendkim/TrustedHosts || true
    echo "$DOMAIN" >> /etc/opendkim/TrustedHosts || true
    chmod 644 /etc/opendkim/TrustedHosts || true

    [ -f /etc/opendkim.conf ] && cp /etc/opendkim.conf /etc/opendkim.conf.bak || true
    cat > /etc/opendkim.conf <<EOF
PidFile /var/run/opendkim/opendkim.pid
Mode    sv
UMask   002
OversignHeaders From
Syslog  yes
LogWhy  yes
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
Socket                  inet:8891@localhost
EOF

    local service_file="/lib/systemd/system/opendkim.service"
    if [ -f "$service_file" ] && ! grep -q '^User=' "$service_file"; then
        sed -i '/^\[Service\]/aUser=opendkim\nGroup=opendkim' "$service_file" || true
    fi
    systemctl daemon-reload || true
    print_status "opendkim.conf 配置完成。" true
}

# logrotate config
configure_logrotate() {
    print_status "正在配置 logrotate 以限制邮件日志大小..."
    local mail_log_path="/var/log/mail.log"
    local logrotate_config="/etc/logrotate.d/postfix-custom"

    if ! command -v logrotate >/dev/null 2>&1; then
        apt-get install -y logrotate &> /dev/null || true
    fi

    cat > "$logrotate_config" <<EOF
$mail_log_path {
    daily
    size 10M
    rotate 1
    compress
    missingok
    notifempty
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate || true
    endscript
}
EOF

    print_status "Logrotate 配置已写入 $logrotate_config，邮件日志将被限制在 10MB。" true
}

optimizing_system(){
    print_status "正在配置系统参数以进行网络和文件句柄优化..."
    # (略) 保留原脚本的 sysctl/limits 修改逻辑（如需可启用）
	sed -i '/fs.file-max/d' /etc/sysctl.conf
	sed -i '/fs.inotify.max_user_instances/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_tw_reuse/d' /etc/sysctl.conf
	sed -i '/net.ipv4.ip_local_port_range/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
	sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
	sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
	sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
	sed -i '/net.core.wmem_default/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_max_tw_buckets/d' /etc/sysctl.conf
	sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
	sed -i '/net.core.netdev_max_backlog/d' /etc/sysctl.conf
 	sed -i '/net.ipv4.tcp_slow_start_after_idle/d' /etc/sysctl.conf
	sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
	echo "fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 16384 262144 8388608
net.ipv4.tcp_wmem = 32768 524288 16777216
net.core.somaxconn = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.wmem_default = 2097152
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_max_syn_backlog = 10240
net.core.netdev_max_backlog = 10240
net.ipv4.tcp_slow_start_after_idle = 0
# forward ipv4
net.ipv4.ip_forward = 1">>/etc/sysctl.conf
	sysctl -p
	echo "*               soft    nofile           1000000
*               hard    nofile          1000000">/etc/security/limits.conf
	echo "ulimit -SHn 1000000">>/etc/profile
    print_status "系统优化函数已加载，如需启用请在脚本中调用。"
}

install_postfix() {
    # 修复：确保在开始安装前检查并修复 dpkg 状态
    check_system

    if dpkg -s postfix >/dev/null 2>&1; then
        print_status "Postfix 已安装。"
        read -p "是否卸载现有 Postfix 并重新安装？(y/n) [Y]: " confirm
        confirm=${confirm:-y}
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            uninstall_all
        else
            print_status "已取消重新安装。请注意，不重新安装可能导致配置冲突。"
            return
        fi
    else
        print_status "Postfix 未安装。"
    fi

    # ----------------------------------------------------
    # 安装步骤 1/5: 更新包列表
    # ----------------------------------------------------
    echo -e "\n${YELLOW}--- 1/5: 正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL... (1/5) 更新系统包列表 ---${NC}"
    apt-get update -y &> /dev/null

    # ----------------------------------------------------
    # 安装步骤 2/5: 安装核心服务 (动态版本选择)
    # ----------------------------------------------------
    echo -e "\n${YELLOW}--- 2/5: 正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL... (2/5) 安装核心服务 ---${NC}"

    local packages="opendkim opendkim-tools postfix-policyd-spf-python sasl2-bin libsasl2-modules"
    local version_to_install=""
    local install_successful=false
    local INSTALL_LOG="$LOG_DIR/apt_install_temp.log" # 确保在函数内定义和使用

    print_status "APT 安装日志将写入 $INSTALL_LOG" true


    # 1. 查找最高可用的 3.10.* 版本
    print_status "正在查询 Postfix $POSTFIX_TARGET_VERSION.* 系列的稳定版本..."

    # 临时禁用 set -e，防止 grep/sort/head 失败时脚本退出
    set +e
    # 注意：这里的 packages 变量似乎在整个函数中是全局/局部定义的，
    # 我们需要确保在回退安装时它也包含所有必要的依赖包。
    # 假设 $packages 包含 'postfix-mysql opendkim opendkim-tools ...' 等依赖包
    version_to_install=$(apt-cache policy postfix | \
        grep -oP "$POSTFIX_TARGET_VERSION\\.[0-9]+\\S*" | \
        sort -rV | \
        head -n 1 | \
        tr -d '[:space:]')
    set -e # 重新启用 set -e

    INSTALL_ATTEMPTED=false # 标记是否尝试过安装

    if [ -n "$version_to_install" ]; then
        INSTALL_ATTEMPTED=true
        echo -e "${GREEN}找到稳定版本: Postfix $version_to_install，正在尝试安装...${NC}"
        print_status "尝试安装 Postfix $version_to_install..." true

        # Start installation in background with spinner, redirecting all output to the temp log
        {
            # 依赖 DEBIAN_FRONTEND=noninteractive
            apt-get install -y postfix="$version_to_install" $packages 2>&1
        } > "$INSTALL_LOG" &
        local install_pid=$!

        printf "${YELLOW}  正在安装 Postfix ${version_to_install}...${NC}" >&2
        spinner $install_pid
        wait $install_pid
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            printf "${GREEN}[完成] ${NC}Postfix ${version_to_install} 安装成功。\n" >&2
            install_successful=true
        else
            printf "\n" >&2 # 失败时打印新行
            print_warning "安装 Postfix $version_to_install 失败（退出码 $exit_code）。"
            # 打印错误日志的最后几行
            print_error "详细错误请查看 $INSTALL_LOG 的最后几行！"
            if [ -f "$INSTALL_LOG" ]; then
                tail -n 10 "$INSTALL_LOG" >&2
            fi
        fi
    else
        print_warning "系统仓库中未找到任何 Postfix $POSTFIX_TARGET_VERSION.* 版本。"
    fi

    # 2. 如果指定版本未安装或安装失败 (install_successful=false)，则尝试安装系统默认版本
    if [ "$install_successful" = false ]; then
        # 避免在第一次尝试安装成功时再次打印警告
        if [ "$INSTALL_ATTEMPTED" = true ]; then
             print_status "现在尝试回退到安装仓库中可用的默认版本..."
        else
             # 如果从未尝试安装指定版本 (即 $version_to_install 为空)
             print_status "直接尝试安装仓库中可用的默认版本..."
        fi

        # 使用默认的 'postfix' 包名，让 apt 选择仓库中最新的
        {
            # 依赖 DEBIAN_FRONTEND=noninteractive
            apt-get install -y postfix $packages 2>&1
        } > "$INSTALL_LOG" &
        local default_install_pid=$!

        printf "${YELLOW}  正在安装 Postfix (默认版本)...${NC}" >&2
        spinner $default_install_pid
        wait $default_install_pid
        local default_exit_code=$?

        if [ $default_exit_code -eq 0 ]; then
            printf "${GREEN}[完成] ${NC}Postfix (默认版本) 安装成功。\n" >&2
            install_successful=true
        else
            printf "\n" >&2 # 失败时打印新行
            print_error "安装 Postfix 默认版本失败（退出码 $default_exit_code）。"
            # 打印错误日志的最后几行
            print_error "详细错误请查看 $INSTALL_LOG 的最后几行！"
            if [ -f "$INSTALL_LOG" ]; then
                tail -n 10 "$INSTALL_LOG" >&2
            fi
            # 只有当默认安装也失败时，才最终退出脚本
            print_error "核心邮件服务安装最终失败，请检查系统和仓库配置。"
            exit 1
        fi
    fi


    print_status "核心邮件服务安装成功。"

    # 生成/更新 SMTP 账户：如果变量为空，则生成新的凭证
    if [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
        print_status "SMTP 账户凭证未在配置文件中找到，正在生成新凭证..."
        SMTP_USER="smtp_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
        SMTP_PASS="$(openssl rand -base64 12)"

        # 调用 get_user_input 中的保存逻辑来持久化新的凭证
        # 这里直接调用保存配置逻辑
        print_status "正在保存新的 SMTP 凭证到 $CONFIG_FILE..."
        cat > "$CONFIG_FILE" <<EOF
CLOUDFLARE_EMAIL="$CLOUDFLARE_EMAIL"
CLOUDFLARE_API_KEY="$CLOUDFLARE_API_KEY"
DOMAIN="$DOMAIN"
SMTP_USER="$SMTP_USER"
SMTP_PASS="$SMTP_PASS"
EOF
        chmod 600 "$CONFIG_FILE"
        print_status "SMTP 账户已生成，并保存到 $CONFIG_FILE" true
    else
        print_status "使用配置文件中已有的 SMTP 账户凭证。" true
    fi

    # 移除旧的 credentials 文件和目录 (清理遗留文件)
    if [ -f "$SCRIPT_DIR/smtp/credentials" ]; then
        rm -f "$SCRIPT_DIR/smtp/credentials" || true
        rmdir "$SCRIPT_DIR/smtp" 2>/dev/null || true
    fi


    get_external_ip
    get_zone_id

    # ----------------------------------------------------
    # 安装步骤 3/5: DKIM 密钥生成和 DNS 更新
    # ----------------------------------------------------
    echo -e "\n${YELLOW}--- 3/5: 正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL... (3/5) DKIM/DNS 配置 ---${NC}"

    add_dns_records

    print_status "正在生成 DKIM 密钥 (2048位)..."
    local dkim_dir="/etc/dkimkeys/$MAIN_DOMAIN"
    mkdir -p "$dkim_dir"
    cd "$dkim_dir"

    if ! opendkim-genkey -b 2048 -d "$MAIN_DOMAIN" -s "$DKIM_SELECTOR" &> /dev/null; then
        print_error "DKIM 密钥生成失败！请检查 opendkim-genkey 命令。"
        exit 1
    fi
    print_status "DKIM 密钥已成功生成。" true

    chown -R opendkim:opendkim "$dkim_dir"
    chmod -R 700 "$dkim_dir"

    # 修复了 DKIM 公钥提取逻辑，确保只提取公钥部分
    dkim_public_key=$(grep -oP '".*"' "$DKIM_SELECTOR.txt" | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\t')
    if [ -z "$dkim_public_key" ]; then
        print_error "无法提取 DKIM 公钥，请检查 $DKIM_SELECTOR.txt"
        exit 1
    fi

    print_status "处理 DKIM TXT 记录 (检查同名记录)..."
    local dkim_name="$DKIM_SELECTOR._domainkey.$MAIN_DOMAIN"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$dkim_name&type=TXT")

    if "$USE_JQ"; then record_id=$(echo "$response" | jq -r '.result[0].id // ""'); else record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(data['result'][0]['id'] if data.get('result') and data['result'] else '')" "TEMP_RESPONSE_FILE=$TEMP_RESPONSE_FILE"); fi

    local json_data=$(jq -n --arg name "$dkim_name" --arg content "v=DKIM1; h=sha256; k=rsa; p=$dkim_public_key" '{type: "TXT", name: $name, content: $content, ttl: 120}')

    local dummy_response # 用于捕获 PUT/POST API 调用的输出
    if [ -n "$record_id" ]; then
        print_status "DKIM TXT 记录已存在，更新记录 ID: $record_id" true
        dummy_response=$(cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data")
    else
        print_status "DKIM TXT 记录不存在，创建新记录: $dkim_name" true
        dummy_response=$(cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data")
    fi
    print_status "DKIM DNS 记录处理完成。"

    # ----------------------------------------------------
    # 安装步骤 4/5: 核心配置
    # ----------------------------------------------------
    echo -e "\n${YELLOW}--- 4/5: 正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL... (4/5) 配置核心组件 ---${NC}"
    generate_self_signed_cert
    configure_postfix
    configure_policyd
    configure_sasl # <<< 包含 SASL 权限和启动顺序的修复
    configure_opendkim
    configure_logrotate
    restart_all_services

    # ----------------------------------------------------
    # 安装步骤 5/5: 别名和系统优化
    # ----------------------------------------------------
    echo -e "\n${YELLOW}--- 5/5: 正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL... (5/5) 配置虚拟别名和系统优化 ---${NC}"

    VIRTUAL_FILE="/etc/postfix/virtual"
    DOMAIN_EMAIL="$DOMAIN"

    if [ ! -f "$VIRTUAL_FILE" ]; then
        touch "$VIRTUAL_FILE"
    fi

    for USER in "$SMTP_USER" "no-reply" "dmarc" "postmaster"; do
        if ! id "$USER" &>/dev/null; then
            useradd -m "$USER" &> /dev/null
        fi
    done

    # 自动添加虚拟别名映射（如已存在则不重复）
    grep -q "^@${DOMAIN_EMAIL}[[:space:]]" "$VIRTUAL_FILE" 2>/dev/null || \
        echo "@${DOMAIN_EMAIL}    $SMTP_USER" >> "$VIRTUAL_FILE"
    grep -q "^no-reply@${DOMAIN_EMAIL}[[:space:]]" "$VIRTUAL_FILE" 2>/dev/null || \
        echo "no-reply@${DOMAIN_EMAIL}    no-reply" >> "$VIRTUAL_FILE"
    grep -q "^dmarc@${DOMAIN_EMAIL}[[:space:]]" "$VIRTUAL_FILE" 2>/dev/null || \
        echo "dmarc@${DOMAIN_EMAIL}    dmarc" >> "$VIRTUAL_FILE"
    grep -q "^postmaster@${DOMAIN_EMAIL}[[:space:]]" "$VIRTUAL_FILE" 2>/dev/null || \
        echo "postmaster@${DOMAIN_EMAIL}    postmaster" >> "$VIRTUAL_FILE"

    postmap "$VIRTUAL_FILE" &> /dev/null
    systemctl reload postfix &> /dev/null

    print_status "Postfix、OpenDKIM 和 Postfix Policyd 安装和配置已完成！"
    print_status "请验证 Cloudflare DNS 记录是否已生效。"

    optimizing_system

    view_smtp_details # 显示 === SMTP 账户信息 ===

    # 显式地尝试清除输入缓冲中的所有字符
    # -t 0.1 设置超时为 0.1 秒
    # -n 10000 尝试读取最多 10000 个字符
    read -t 0.1 -n 10000 || true

    print_warning "系统优化配置（如 limits.conf）需要重启 VPS 才能完全生效！"
    read -p "需要重启 VPS 后，才能生效系统优化配置，是否现在重启 ? [Y/n] :" yn
    [ -z "${yn}" ] && yn="y"

    if [[ $yn == [Yy] ]]; then
        print_status "VPS 重启中... 请等待几分钟后重新连接。"
        reboot
    else
        print_status "已取消重启。请注意，手动运行 'reboot' 以应用优化配置。"
    fi
}

view_smtp_details() {
    if [ -z "$DOMAIN" ]; then
        print_error "请先运行安装脚本以设置域名和账户信息。"
        sleep 2
        return
    fi
    show_header
    echo -e "${GREEN}=== SMTP 账户信息 ===${NC}"
    echo -e "IP 地址: ${GREEN}$EXTERNAL_IP${NC}"
    echo -e "端口: ${GREEN}465 (SMTPS), 587 (STARTTLS)${NC}"

    if [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        # 直接使用全局变量 SMTP_USER 和 SMTP_PASS (从 PostFix_Cloudflare.conf 加载)
        echo -e "SMTP 邮箱: ${GREEN}no-reply@${DOMAIN}${NC}"
        echo -e "SMTP 账号: ${GREEN}${SMTP_USER}@${DOMAIN}${NC}"
        echo -e "SMTP 密码: ${GREEN}$SMTP_PASS${NC}"
    else
        print_warning "未找到 SMTP 凭证，请先安装 Postfix 或检查 $CONFIG_FILE。"
    fi

    echo -e "${YELLOW}----------------------------------------------------${NC}"
    read -p "按 Enter 继续..."
}


get_user_input() {
    print_status "正在执行初步检测..."
    check_json_parser

    local needs_save=false

    if [ -f "$CONFIG_FILE" ]; then
        print_status "加载配置文件：$CONFIG_FILE"
        set -a
        source "$CONFIG_FILE"
        set +a
        print_status "已加载配置：Email: ${CLOUDFLARE_EMAIL:-未设置}, Domain: ${DOMAIN:-未设置}" true
    fi

    if [ -z "$CLOUDFLARE_EMAIL" ]; then
        read -p "请输入您的 Cloudflare 邮箱: " CLOUDFLARE_EMAIL
        needs_save=true
    fi
    if [ -z "$CLOUDFLARE_API_KEY" ]; then
        read -p "请输入您的 Cloudflare API 密钥: " CLOUDFLARE_API_KEY
        needs_save=true
    fi
    if [ -z "$DOMAIN" ]; then
        read -p "请输入您的域名 (例如：example.com 或 sub.example.com): " DOMAIN
        needs_save=true
    fi

    validate_variable "CLOUDFLARE_EMAIL" "$CLOUDFLARE_EMAIL"
    validate_variable "CLOUDFLARE_API_KEY" "$CLOUDFLARE_API_KEY"
    validate_variable "DOMAIN" "$DOMAIN"

    if [ -z "$CLOUDFLARE_EMAIL" ] || [ -z "$CLOUDFLARE_API_KEY" ] || [ -z "$DOMAIN" ]; then
        print_error "Cloudflare 邮箱、API 密钥和域名不能为空。"
        exit 1
    fi

    if $needs_save || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ]; then
        print_status "正在保存/更新配置到 $CONFIG_FILE..."

        # === 统一的兼容方式：使用 Command Group 重定向写入 (最安全) ===
        # 这种方式在 Debian 和 Ubuntu 环境中都更稳定，避免了 Here Document
        # 引起的 /dev/fd/ 问题。
        print_status "使用最兼容的方式保存配置（分行写入）。"

        {
            # 注意：配置值使用双引号，以确保 source 时包含空格的密码等值能正确解析。
            echo "CLOUDFLARE_EMAIL=\"$CLOUDFLARE_EMAIL\""
            echo "CLOUDFLARE_API_KEY=\"$CLOUDFLARE_API_KEY\""
            echo "DOMAIN=\"$DOMAIN\""
            echo "SMTP_USER=\"$SMTP_USER\""
            echo "SMTP_PASS=\"$SMTP_PASS\""
        } > "$CONFIG_FILE"
        # === 统一的兼容方式结束 ===

        chmod 600 "$CONFIG_FILE"
        print_status "配置已保存。" true
    fi

    get_external_ip
    get_zone_id

    if [ "$DOMAIN" = "$MAIN_DOMAIN" ]; then
        DKIM_SELECTOR="key"
    else
        DKIM_SELECTOR="${DOMAIN%.$MAIN_DOMAIN}"
    fi
    print_status "DKIM 选择器设置为：$DKIM_SELECTOR" true

    hostnamectl set-hostname "$DOMAIN" &> /dev/null || true
    print_status "主机名已设置为 $DOMAIN" true
}

check_postfix_status() {
    clear
    show_header
    echo -e "${GREEN}=== Postfix 状态 ===${NC}"
    if dpkg -s postfix >/dev/null 2>&1; then
        print_status "Postfix 已安装。"
        service postfix status | cat
    else
        print_warning "Postfix 未安装。"
    fi
    echo -e "${YELLOW}----------------------------------------------------${NC}"
    read -p "按 Enter 继续..."
}

# restart services (修复/简化重启逻辑)
restart_all_services() {
    print_status "正在重启 OpenDKIM、saslauthd 和 Postfix 服务..."
    set +e
    systemctl restart opendkim.service 2>/dev/null || service opendkim restart 2>/dev/null || true
    systemctl restart saslauthd.service 2>/dev/null || service saslauthd restart 2>/dev/null || true
    systemctl restart postfix.service 2>/dev/null || service postfix restart 2>/dev/null || true
    set -e
    print_status "服务重启命令已发送。"
    sleep 1
    # 重新加载 Postfix maps
    postmap /etc/postfix/virtual 2>/dev/null || true
    postmap /etc/postfix/header_checks 2>/dev/null || true
}

# 检查监听端口，帮助确认 465/587 是否在监听
check_listening_ports() {
    print_status "检查 Postfix 是否在监听 25、465、587 端口..."
    ss -tlnp | grep -E "(LISTEN).*:(25|465|587)\b" || ss -tlnp | grep -E "master|postfix|smtpd" || true
}

view_queue() {
    clear
    show_header
    echo -e "${GREEN}=== Postfix 队列 ===${NC}"
    mailq
    echo -e "${YELLOW}----------------------------------------------------${NC}"
    read -p "按 Enter 继续..."
}

flush_queue() {
    print_status "正在刷新 Postfix 队列..."
    postfix flush || true
    read -p "按 Enter 继续..."
}

delete_queue() {
    read -p "确定要删除所有 Postfix 队列邮件吗？(y/n) [Y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        print_status "正在删除所有 Postfix 队列邮件..."
        postsuper -d ALL &> /dev/null || true
        restart_all_services
        print_status "队列已清空并已重启服务。"
    else
        print_status "已取消删除队列。"
    fi
    read -p "按 Enter 继续..."
}

view_logs() {
    clear
    show_header
    echo -e "${GREEN}=== 脚本日志 (${LOG_FILE}) ===${NC}"
    tail -n 200 "$LOG_FILE" || true
    echo -e "${YELLOW}----------------------------------------------------${NC}"
    read -p "按 Enter 继续..."
}

delete_logs() {
    read -p "确定要删除所有脚本日志吗？(y/n) [Y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        print_status "正在删除日志..."
        rm -f "$LOG_FILE" "$INSTALL_LOG" "$TEMP_RESPONSE_FILE" || true
        print_status "日志已删除。"
        init_logs
    else
        print_status "已取消删除日志。"
    fi
    read -p "按 Enter 继续..."
}

show_main_menu() {
    show_header
    echo -e "${GREEN}=== 主菜单 ===${NC}"
    echo -e " ${YELLOW}1.${NC} 📥 安装/卸载所有邮件服务"
    echo -e " ${YELLOW}2.${NC} 🛠️ Postfix 核心配置与服务管理"
    echo -e " ${YELLOW}3.${NC} 📬 Postfix 队列与邮件日志分析"
    echo -e " ${YELLOW}4.${NC} 📋 脚本日志管理"
    echo -e " ${YELLOW}5.${NC} 🚪 退出"
    echo -e "${YELLOW}----------------------------------------------------${NC}"
}

install_uninstall_menu() {
    while true; do
        clear
        show_header
        echo -e "${GREEN}=== 安装/卸载 菜单 ===${NC}"
        echo -e " ${YELLOW}1.${NC} ⚡ 开始安装 Postfix、DKIM 和 SASL..."
        echo -e " ${YELLOW}2.${NC} 🗑️ 卸载所有相关邮件服务"
        echo -e " ${YELLOW}3.${NC} 🔍 查看 Postfix 状态"
        echo -e " ${YELLOW}q.${NC} ↩️ 返回主菜单"
        echo -e "${YELLOW}----------------------------------------------------${NC}"
        read -p "输入选择: " choice
        case $choice in
            1) install_postfix ; read -p "按 Enter 继续..." ;;
            2) uninstall_all ; read -p "按 Enter 继续..." ;;
            3) check_postfix_status ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

postfix_management_menu() {
    while true; do
        clear
        show_header
        echo -e "${GREEN}=== Postfix 管理 菜单 ===${NC}"
        echo -e " ${YELLOW}1.${NC} 🔄 重启所有服务 (Postfix/DKIM/SASL)"
        echo -e " ${YELLOW}2.${NC} 📄 查看 main.cf 配置"
        local dkim_public_key_path="/etc/dkimkeys/$MAIN_DOMAIN/$DKIM_SELECTOR.txt"
        if [ -f "$dkim_public_key_path" ]; then
            echo -e " ${YELLOW}3.${NC} 🔑 查看 DKIM 公钥文件 (${DKIM_SELECTOR}.txt)"
        else
            echo -e " ${YELLOW}3.${NC} 🔑 查看 DKIM 公钥文件 (文件未找到)"
        fi
        echo -e " ${YELLOW}4.${NC} 🛡️ 查看 Postfix Policyd 配置"
        echo -e " ${YELLOW}5.${NC} 📧 查看 SMTP 账户信息"
        echo -e " ${YELLOW}6.${NC} 🔎 检查 25/465/587 监听"
        echo -e " ${YELLOW}q.${NC} ↩️ 返回主菜单"
        echo -e "${YELLOW}----------------------------------------------------${NC}"
        read -p "输入选择: " choice
        case $choice in
            1) restart_all_services ;;
            2) print_status "正在显示 main.cf 配置..." ; less /etc/postfix/main.cf ; read -p "按 Enter 继续..." ;;
            3) print_status "正在显示 DKIM 公钥..." ; cat "$dkim_public_key_path" 2>/dev/null || print_warning "DKIM 文件未找到" ; read -p "按 Enter 继续..." ;;
            4) print_status "正在显示 Postfix Policyd 配置..." ; grep 'policy-spf' /etc/postfix/master.cf 2>/dev/null || print_warning "policy-spf 未配置" ; read -p "按 Enter 继续..." ;;
            5) view_smtp_details ;;
            6) check_listening_ports ; read -p "按 Enter 继续..." ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

queue_management_menu() {
    while true; do
        clear
        show_header
        echo -e "${GREEN}=== Postfix 队列管理/日志分析 ===${NC}"
        echo -e " ${YELLOW}1.${NC} 📬 查看队列 (mailq)"
        echo -e " ${YELLOW}2.${NC} 💨 刷新队列 (postfix flush)"
        echo -e " ${YELLOW}3.${NC} ❌ 删除所有队列邮件"
        echo -e " ${YELLOW}4.${NC} ✅ 查看成功日志 (status=sent)"
        echo -e " ${YELLOW}5.${NC} 👤 查看成功收件人列表"
        echo -e " ${YELLOW}6.${NC} 🗑️ 查看退信 (bounced)"
        echo -e " ${YELLOW}7.${NC} ⛔ 查看拒绝 (reject)"
        echo -e " ${YELLOW}8.${NC} 🛡️ 查看 SPF 拦截"
        echo -e " ${YELLOW}9.${NC} 🧹 清空 /var/log/mail.log"
        echo -e " ${YELLOW}q.${NC} ↩️ 返回主菜单"
        echo -e "${YELLOW}----------------------------------------------------${NC}"
        read -p "输入选择: " choice
        case $choice in
            1) view_queue ;;
            2) flush_queue ;;
            3) delete_queue ;;
            4) print_status "查看成功日志 (status=sent)..." ; grep 'status=sent' /var/log/mail.log | less ;;
            5) print_status "查看成功收件人列表..." ; grep 'status=sent' /var/log/mail.log | awk -F'to=<' '{if (NF>1) print $2}' | awk -F'>' '{print $1}' | sort | uniq | less ;;
            6) print_status "查看退信 (bounced)..." ; grep 'status=bounced' /var/log/mail.log | less ;;
            7) print_status "查看拒绝 (reject)..." ; grep reject /var/log/mail.log | less ;;
            8) print_status "查看 SPF 拦截..." ; grep SPF /var/log/mail.log | less ;;
            9)
                read -p "确定要清空 /var/log/mail.log 吗？(y/n) [Y]: " confirm
                confirm=${confirm:-y}
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    print_status "清空 /var/log/mail.log ..."
                    cat /dev/null > /var/log/mail.log || true
                    print_status "/var/log/mail.log 已清空。"
                else
                    print_status "已取消清空。"
                fi
                read -p "按 Enter 继续..."
                ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

log_management_menu() {
    while true; do
        clear
        show_header
        echo -e "${GREEN}=== 脚本日志管理 ===${NC}"
        echo -e " ${YELLOW}1.${NC} 📜 查看脚本日志"
        echo -e " ${YELLOW}2.${NC} 🗑️ 删除脚本日志 (包括安装临时日志)"
        echo -e " ${YELLOW}3.${NC} 🔎 查看上次 APT 安装临时日志"
        echo -e " ${YELLOW}q.${NC} ↩️ 返回主菜单"
        echo -e "${YELLOW}----------------------------------------------------${NC}"
        read -p "输入选择: " choice
        case $choice in
            1) view_logs ;;
            2) delete_logs ;;
            3) print_status "正在显示上次 APT 安装临时日志 (${INSTALL_LOG})..." ; less "$INSTALL_LOG" ; read -p "按 Enter 继续..." ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

main() {
    init_logs
    detect_os # <--- 新增
    get_user_input

    while true; do
        clear
        show_main_menu
        read -p "输入选择: " choice
        case $choice in
            1) install_uninstall_menu ;;
            2) postfix_management_menu ;;
            3) queue_management_menu ;;
            4) log_management_menu ;;
            5) print_status "退出脚本。" ; exit 0 ;;
            *) print_error "无效选择，请重新输入。" ; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main
