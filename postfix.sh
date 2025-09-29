#!/bin/bash

# cf.sh - Postfix 安装、调试和管理脚本
# 基于 Debian/Ubuntu 系统（使用 apt）。
# 运行前请确保你拥有 root 权限：sudo ./cf.sh

set -e
export LC_ALL=C

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/root/Postfix_logs"
TEMP_RESPONSE_FILE="$LOG_DIR/cloudflare_api_response.txt"
LOG_FILE="$LOG_DIR/Postfix_install.log"
CONFIG_FILE="$SCRIPT_DIR/Postfix.conf"
USE_JQ=true
CLOUDFLARE_EMAIL=""
CLOUDFLARE_API_KEY=""
DOMAIN=""
ZONE_ID=""
EXTERNAL_IP=""
MAIN_DOMAIN=""
SMTP_USER=""
SMTP_PASS=""
DKIM_SELECTOR=""  # 动态设置
CERT_DIR="/etc/postfix/ssl"
CERT_FILE="$CERT_DIR/smtpd.crt"
KEY_FILE="$CERT_DIR/smtpd.key"

init_logs() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

print_status() {
    echo -e "${GREEN}[信息]${NC} $1" >&2
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1" >&2
    echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

check_json_parser() {
    if command -v jq >/dev/null 2>&1; then
        print_status "检测到 jq，将优先使用 jq 解析 JSON。"
        USE_JQ=true
    elif command -v python3 >/dev/null 2>&1; then
        print_warning "未检测到 jq，将使用 Python 解析 JSON。"
        USE_JQ=false
    else
        print_status "未找到 jq，正在自动安装..."
        apt-get update -y
        apt-get install -y jq
        if command -v jq >/dev/null 2>&1; then
            print_status "jq 已成功安装。"
            USE_JQ=true
        else
            print_error "无法安装 jq，请检查你的网络或仓库配置。"
            print_warning "尝试使用 Python 解析 JSON..."
            if command -v python3 >/dev/null 2>&1; then
                USE_JQ=false
            else
                print_error "也未找到 python3，请手动安装 jq 或 python3。"
                print_error "安装 jq：sudo apt-get install jq"
                exit 1
            fi
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

cloudflare_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local http_code
    local curl_cmd

    : > "$TEMP_RESPONSE_FILE"
    : > "$LOG_DIR/cloudflare_http_code.txt"

    curl_cmd=(curl -s -X "$method" "https://api.cloudflare.com/client/v4/$endpoint" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        -H "Content-Type: application/json")

    if [ -n "$data" ]; then
        curl_cmd+=(--data-raw "$data")
    fi

    print_status "执行 Cloudflare API: $method $endpoint"
    if [ -n "$data" ]; then
        print_status "请求数据: $data"
    fi

    "${curl_cmd[@]}" -o "$TEMP_RESPONSE_FILE" -w "%{http_code}" > "$LOG_DIR/cloudflare_http_code.txt"
    http_code=$(cat "$LOG_DIR/cloudflare_http_code.txt")
    local response
    response=$(cat "$TEMP_RESPONSE_FILE")

    print_status "HTTP 状态码: $http_code"

    if [ -z "$response" ]; then
        print_error "Cloudflare API 无响应，请检查网络连接或 API 凭证。"
        exit 1
    fi

    if "$USE_JQ"; then
        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            print_error "Cloudflare API 返回无效 JSON，已写入 $TEMP_RESPONSE_FILE"
            exit 1
        fi
    else
        if ! python3 -c "import json, os; json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read())" >/dev/null 2>&1; then
            print_error "Cloudflare API 返回无效 JSON，已写入 $TEMP_RESPONSE_FILE"
            exit 1
        fi
    fi

    if [ "$http_code" -ge 400 ]; then
        print_error "Cloudflare API 返回 HTTP 错误: $http_code"
        if "$USE_JQ"; then
            error_msg=$(echo "$response" | jq -r '.errors[0].message // "未知错误"')
            error_code=$(echo "$response" | jq -r '.errors[0].code // "无错误代码"')
            print_error "Cloudflare 错误详情: 代码 $error_code, 消息 $error_msg"
        else
            error_msg=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(data['errors'][0]['message'] if data.get('errors') else '未知错误')" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE")
            error_code=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(data['errors'][0]['code'] if data.get('errors') else '无错误代码')" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE")
            print_error "Cloudflare 错误详情: 代码 $error_code, 消息 $error_msg"
        fi
        print_error "响应已写入 $TEMP_RESPONSE_FILE"
        exit 1
    fi

    cat "$TEMP_RESPONSE_FILE"
}

get_external_ip() {
    print_status "正在获取外网 IP 地址..."
    EXTERNAL_IP=$(curl -s ifconfig.me)
    if [ -z "$EXTERNAL_IP" ]; then
        print_error "无法获取外网 IP 地址"
        exit 1
    fi
    validate_variable "EXTERNAL_IP" "$EXTERNAL_IP"
    print_status "外网 IP：$EXTERNAL_IP"
}

add_dns_records() {
    local json_data
    local response
    local record_id
    local record_name

    # 计算记录名称（子域名或主域名）
    if [ "$DOMAIN" = "$MAIN_DOMAIN" ]; then
        record_name="@"
    else
        record_name="${DOMAIN%.$MAIN_DOMAIN}"
    fi

    print_status "开始处理 DNS 记录..."

    # 检查并更新/添加 A 记录：$DOMAIN
    print_status "处理 A 记录：$DOMAIN -> $EXTERNAL_IP"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=A")
    if "$USE_JQ"; then
        record_id=$(echo "$response" | jq -r '.result[0].id // ""')
    else
        record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(data['result'][0]['id'] if data['result'] else '')" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE")
    fi
    json_data=$(jq -n --arg name "$record_name" --arg ip "$EXTERNAL_IP" '{type: "A", name: $name, content: $ip, ttl: 120, proxied: false}')
    if [ -n "$record_id" ]; then
        print_status "A 记录已存在，更新记录：$DOMAIN -> $EXTERNAL_IP"
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data"
    else
        print_status "A 记录不存在，创建记录：$DOMAIN -> $EXTERNAL_IP"
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data"
    fi

    # 检查并更新/添加 MX 记录
    print_status "处理 MX 记录：$DOMAIN -> $DOMAIN"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=MX")
    if "$USE_JQ"; then
        record_id=$(echo "$response" | jq -r --arg mx "$DOMAIN" '.result[] | select(.content == $mx) | .id // ""')
    else
        record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['content'] == os.environ.get('MX')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" MX="$DOMAIN")
    fi
	
    json_data=$(jq -n --arg name "$record_name" --arg mx "$DOMAIN" '{type: "MX", name: $name, content: $mx, priority: 10, ttl: 120}')
	#-------------------------------------------------------------------------------------------
    if [ -n "$record_id" ]; then
        print_status "MX 记录已存在，更新记录：$DOMAIN -> $MAIN_DOMAIN"
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data"
    else
        print_status "MX 记录不存在，创建记录：$DOMAIN -> $MAIN_DOMAIN"
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data"
    fi

    # 检查并更新/添加 SPF TXT 记录
    local spf_value="v=spf1 a mx ip4:$EXTERNAL_IP ~all"
    print_status "处理 SPF TXT 记录：$spf_value"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$DOMAIN&type=TXT")
    if "$USE_JQ"; then
        record_id=$(echo "$response" | jq -r --arg spf "$spf_value" '.result[] | select(.content == $spf) | .id // ""')
    else
        record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['content'] == os.environ.get('SPF')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" SPF="$spf_value")
    fi
    json_data=$(jq -n --arg name "$record_name" --arg spf "$spf_value" '{type: "TXT", name: $name, content: $spf, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "SPF 记录已存在，更新记录：$spf_value"
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data"
    else
        print_status "SPF 记录不存在，创建记录：$spf_value"
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data"
    fi

    # 检查并更新/添加 DMARC TXT 记录
    local dmarc_value="v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN"
    print_status "处理 DMARC TXT 记录：$dmarc_value"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=_dmarc.$DOMAIN&type=TXT")
    if "$USE_JQ"; then
        record_id=$(echo "$response" | jq -r --arg dmarc "$dmarc_value" '.result[] | select(.content == $dmarc) | .id // ""')
    else
        record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['content'] == os.environ.get('DMARC')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" DMARC="$dmarc_value")
    fi
    json_data=$(jq -n --arg name "_dmarc.$record_name" --arg dmarc "$dmarc_value" '{type: "TXT", name: $name, content: $dmarc, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "DMARC 记录已存在，更新记录：$dmarc_value"
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data"
    else
        print_status "DMARC 记录不存在，创建记录：$dmarc_value"
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data"
    fi

    print_status "DNS 记录处理完成！"
}

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
        if "$USE_JQ"; then
            zone_id_candidate=$(echo "$zones_response" | jq -r --arg d "$parent" '.result[] | select(.name == $d) | .id')
        else
            zone_id_candidate=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['name'] == os.environ.get('PARENT')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" PARENT="$parent")
        fi
    fi
    if [ -z "$zone_id_candidate" ] || [ "$zone_id_candidate" == "null" ]; then
        if "$USE_JQ"; then
            zone_id_candidate=$(echo "$zones_response" | jq -r --arg d "$DOMAIN" '.result[] | select(.name == $d) | .id')
        else
            zone_id_candidate=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['name'] == os.environ.get('DOMAIN')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" DOMAIN="$DOMAIN")
        fi
        if [ -n "$zone_id_candidate" ] && [ "$zone_id_candidate" != "null" ]; then
            MAIN_DOMAIN="$DOMAIN"
        fi
    else
        MAIN_DOMAIN="$parent"
    fi

    if [ -z "$zone_id_candidate" ]; then
        print_error "未找到匹配的 Cloudflare 区域。"
        exit 1
    fi

    ZONE_ID="$zone_id_candidate"
    print_status "找到区域：$MAIN_DOMAIN，ID：$ZONE_ID"
}

check_system() {
    print_status "正在执行系统环境检查..."
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 身份运行！"
        exit 1
    fi

    ulimit -n 102400
    print_status "ulimit -n 已设置为 102400。"

    if ss -tln | grep -q ':25'; then
        print_warning "检测到 25 端口正在被占用。请确认是 Postfix 或其他邮件系统在使用。"
    else
        print_status "25 端口未被占用。"
    fi

    print_status "检查其他邮件系统..."
    if dpkg -s exim4 >/dev/null 2>&1 || dpkg -s sendmail >/dev/null 2>&1; then
        print_warning "检测到其他邮件系统（exim4 或 sendmail）。"
        read -p "是否卸载这些系统？(y/n) [Y]: " confirm
        confirm=${confirm:-y}
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            print_status "正在卸载 exim4 和 sendmail..."
            apt-get purge -y exim4 sendmail
            apt-get autoremove -y
            print_status "其他邮件系统已卸载。"
        else
            print_status "已取消卸载。"
        fi
    else
        print_status "未检测到其他邮件系统。"
    fi
}

uninstall_all() {
    print_status "正在卸载所有邮件相关组件..."
    service postfix stop || true
    service opendkim stop || true
    service saslauthd stop || true
    apt-get purge -y postfix opendkim opendkim-tools postfix-policyd-spf-python sasl2-bin libsasl2-modules
    apt-get autoremove -y
    print_status "所有邮件相关组件已成功卸载。"
}

generate_self_signed_cert() {
    print_status "正在生成自签名 SSL/TLS 证书..."

    mkdir -p "$CERT_DIR"
    service postfix stop || true

    openssl genrsa -out "$KEY_FILE" 2048
    openssl req -new -key "$KEY_FILE" -out "$CERT_DIR/smtpd.csr" -subj "/C=US/ST=State/L=City/O=Self-Signed/CN=$DOMAIN"
    openssl x509 -req -days 365 -in "$CERT_DIR/smtpd.csr" -signkey "$KEY_FILE" -out "$CERT_FILE"

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    print_status "自签名证书已生成，位于 $CERT_FILE"
    service postfix start || true
}

configure_postfix() {
    print_status "正在配置 Postfix main.cf..."

    cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

    cat > /etc/postfix/main.cf <<EOF
myhostname = $DOMAIN
mydomain = $DOMAIN
myorigin = \$mydomain
inet_interfaces = all
default_process_limit = 500
default_destination_concurrency_limit = 3
initial_destination_concurrency = 3
smtp_destination_concurrency_limit = 1
smtp_destination_rate_delay = 10s
minimal_backoff_time = 300s
maximal_backoff_time = 4000s
maximal_queue_lifetime = 1d
inet_protocols = all
mydestination = $myhostname, localhost, $mydomain, $DOMAIN
local_recipient_maps = unix:passwd.byname $virtual_alias_maps
virtual_alias_domains = $DOMAIN
virtual_alias_maps = hash:/etc/postfix/virtual
relay_domains =
relayhost =
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 $EXTERNAL_IP/32
mailbox_size_limit = 0
recipient_delimiter = +
home_mailbox = Maildir/
virtual_alias_maps = hash:/etc/postfix/virtual
smtpd_use_tls = yes
smtpd_tls_cert_file = $CERT_FILE
smtpd_tls_key_file = $KEY_FILE
smtpd_tls_security_level = may
smtp_tls_security_level = may
smtpd_sasl_auth_enable = yes
smtpd_tls_loglevel = 1
disable_vrfy_command = yes
smtpd_tls_received_header = yes
smtpd_sasl_type = cyrus
smtpd_sasl_path = smtpd
smtpd_sasl_security_options = noanonymous
broken_sasl_auth_clients = yes
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    check_policy_service unix:private/policy-spf
header_checks = regexp:/etc/postfix/header_checks
milter_default_action = accept
milter_protocol = 2
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
EOF

    print_status "正在配置 Postfix master.cf..."
    cp /etc/postfix/master.cf /etc/postfix/master.cf.bak

    # 清除旧的 submission 和 smtps 配置
    sed -i '/^submission/d; /^smtps/d;' /etc/postfix/master.cf

    # 重新添加 submission 和 smtps 配置
    cat >> /etc/postfix/master.cf <<EOF
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
  
smtp      inet  n       -       y       -       -       smtpd
  -o smtpd_sasl_auth_enable=no
EOF

    # 修复 sed 语法错误，使用正确的语法来添加 smtpd_tls_security_level=may
    sed -i -e '/^smtp[[:space:]][[:space:]]*inet[[:space:]]/s/$/ -o smtpd_tls_security_level=may/' /etc/postfix/master.cf

    print_status "正在配置邮件头优化..."
    cat > /etc/postfix/header_checks <<EOF
/^Received: from.*/ IGNORE
/^List-Unsubscribe:/ IGNORE
/^List-Unsubscribe-Post:/ IGNORE
/^List-ID:/ IGNORE
/^Reply-To:/ IGNORE
/^Feedback-ID:/ IGNORE
EOF
    postmap /etc/postfix/header_checks
}

configure_policyd() {
    print_status "正在配置 Postfix Policyd (postfix-policyd-spf-python)..."
    if ! grep -q "policy-spf" /etc/postfix/master.cf; then
        print_status "添加 policy-spf 配置到 master.cf..."
        echo "policy-spf unix - n n - - spawn user=policyd-spf argv=/usr/bin/policyd-spf" >> /etc/postfix/master.cf
    else
        print_status "master.cf 已包含 policy-spf 配置。"
    fi
}

configure_sasl() {
    print_status "正在配置 SASL 认证..."
    mkdir -p /etc/postfix/sasl

    print_status "写入 /etc/postfix/sasl/smtpd.conf ..."
    cat > /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: saslauthd
mech_list: plain login
EOF

    print_status "创建 SMTP 认证账户..."
    echo "$SMTP_PASS" | saslpasswd2 -c -u "$DOMAIN" "$SMTP_USER"

    if [ -f /etc/sasldb2 ]; then
        chown root:sasl /etc/sasldb2
        chmod 640 /etc/sasldb2
        adduser postfix sasl || true
    fi

    if [ -f "/etc/default/saslauthd" ]; then
        sed -i 's/^MECHANISMS=.*/MECHANISMS="sasldb"/' /etc/default/saslauthd
        sed -i 's/^START=.*/START=yes/' /etc/default/saslauthd
        # 删除所有旧的 SOCKETDIR 和 OPTIONS 行
        sed -i '/^SOCKETDIR=/d' /etc/default/saslauthd
        sed -i '/^OPTIONS=/d' /etc/default/saslauthd
        # 添加用户指定的 OPTIONS 行，以解决 chroot 认证问题
        echo 'OPTIONS="-c -m /var/spool/postfix/var/run/saslauthd"' >> /etc/default/saslauthd
        echo 'START=yes' >> /etc/default/saslauthd
    fi

    # Postfix chroot 兼容性修正：saslauthd socket 软链接
    SASLAUTHD_RUN_DIR="/var/run/saslauthd"
    POSTFIX_SASLAUTHD_RUN_DIR="/var/spool/postfix/var/run/saslauthd"
    mkdir -p "$POSTFIX_SASLAUTHD_RUN_DIR"
    chown root:sasl "$POSTFIX_SASLAUTHD_RUN_DIR"
    chmod 710 "$POSTFIX_SASLAUTHD_RUN_DIR"
    rm -f "$POSTFIX_SASLAUTHD_RUN_DIR/mux"
    ln -s "$SASLAUTHD_RUN_DIR/mux" "$POSTFIX_SASLAUTHD_RUN_DIR/mux" || true

    print_status "检查 Postfix 虚拟别名映射文件..."
    print_status "检查 /etc/postfix/virtual 和 /etc/postfix/virtual.db ..."
    ls -la /etc/postfix/virtual /etc/postfix/virtual.db 2>/dev/null || {
        print_status "一个或多个文件不存在，继续处理..."
    }

    if [ ! -f /etc/postfix/virtual ]; then
        print_status "创建空文件 /etc/postfix/virtual ..."
        touch /etc/postfix/virtual || print_error "无法创建 /etc/postfix/virtual"
    else
        print_status "/etc/postfix/virtual 已存在，跳过创建"
    fi

    print_status "生成 hash 表 /etc/postfix/virtual.db ..."
    postmap /etc/postfix/virtual || print_error "无法生成 /etc/postfix/virtual.db"

    print_status "验证 /etc/postfix/virtual.db 是否生成..."
    if ls -la /etc/postfix/virtual.db >/dev/null 2>&1; then
        print_status "/etc/postfix/virtual.db 已成功生成"
    else
        print_error "/etc/postfix/virtual.db 未生成"
    fi

    # 配置 systemd override 以兼容 Ubuntu 24.04 的 saslauthd PID 路径问题
    print_status "配置 systemd override 以匹配 chroot PID 路径..."
    mkdir -p /etc/systemd/system/saslauthd.service.d
    cat > /etc/systemd/system/saslauthd.service.d/override.conf << EOF
[Service]
PIDFile=/var/spool/postfix/var/run/saslauthd/saslauthd.pid
EOF
    systemctl daemon-reload
    print_status "systemd override 配置完成。"

    print_status "重启 saslauthd 服务..."
    systemctl restart saslauthd || print_error "saslauthd 重启失败，请检查 journalctl -u saslauthd"
    print_status "SASL 认证配置完成！"
}

configure_opendkim() {
    print_status "配置 OpenDKIM..."

    mkdir -p /etc/opendkim
    chown -R opendkim:opendkim /etc/opendkim

    print_status "正在生成 KeyTable..."
    echo "$DKIM_SELECTOR._domainkey.$MAIN_DOMAIN $MAIN_DOMAIN:$DKIM_SELECTOR:/etc/dkimkeys/$MAIN_DOMAIN/$DKIM_SELECTOR.private" > /etc/opendkim/KeyTable
    chmod 644 /etc/opendkim/KeyTable

    print_status "正在生成 SigningTable..."
    echo "*@$MAIN_DOMAIN $DKIM_SELECTOR._domainkey.$MAIN_DOMAIN" > /etc/opendkim/SigningTable
    echo "*@$DOMAIN $DKIM_SELECTOR._domainkey.$MAIN_DOMAIN" >> /etc/opendkim/SigningTable
    chmod 644 /etc/opendkim/SigningTable

    print_status "正在生成 TrustedHosts..."
    echo "127.0.0.1" > /etc/opendkim/TrustedHosts
    echo "localhost" >> /etc/opendkim/TrustedHosts
    echo "$EXTERNAL_IP" >> /etc/opendkim/TrustedHosts
    echo "$DOMAIN" >> /etc/opendkim/TrustedHosts
    chmod 644 /etc/opendkim/TrustedHosts

    print_status "配置 opendkim.conf..."
    cp /etc/opendkim.conf /etc/opendkim.conf.bak

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

    print_status "正在配置 opendkim.service..."
    local service_file="/lib/systemd/system/opendkim.service"
    if [ -f "$service_file" ] && ! grep -q '^User=' "$service_file"; then
        sed -i '/^\[Service\]/aUser=opendkim\nGroup=opendkim' "$service_file"
        print_status "已添加 User 和 Group 到 opendkim.service。"
    else
        print_status "opendkim.service 已包含用户配置，跳过修改。"
    fi

    systemctl daemon-reload
    print_status "opendkim.conf 配置完成。"
}

install_postfix() {
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

    print_status "正在更新系统包列表..."
    apt-get update -y

    print_status "正在安装 Postfix、OpenDKIM、Postfix Policyd 和 SASL..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y postfix opendkim opendkim-tools postfix-policyd-spf-python sasl2-bin libsasl2-modules

    SMTP_USER="smtp_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    SMTP_PASS="$(openssl rand -base64 12)"
    mkdir -p "$SCRIPT_DIR/smtp"
    echo "$SMTP_USER:$SMTP_PASS" > "$SCRIPT_DIR/smtp/credentials"
    chmod 600 "$SCRIPT_DIR/smtp/credentials"
    print_status "SMTP 账户已生成，并保存到 $SCRIPT_DIR/smtp/credentials"

    get_external_ip
    get_zone_id

    add_dns_records

    print_status "正在生成 DKIM 密钥..."
    local dkim_dir="/etc/dkimkeys/$MAIN_DOMAIN"
    mkdir -p "$dkim_dir"
    cd "$dkim_dir"
    opendkim-genkey -b 2048 -d "$MAIN_DOMAIN" -s "$DKIM_SELECTOR" -v
    print_status "DKIM 密钥已生成在 $dkim_dir"

    print_status "正在修复 DKIM 密钥文件权限..."
    chown -R opendkim:opendkim "$dkim_dir"
    chmod -R 700 "$dkim_dir"
    print_status "DKIM 密钥文件权限已修复。"

    print_status "正在从密钥文件中提取 DKIM 公钥..."
    local dkim_public_key
    #dkim_public_key=$(grep -oP '"v=DKIM1.*?"' "$DKIM_SELECTOR.txt" | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\t')
	dkim_public_key=$(grep -oP '".*"' "$DKIM_SELECTOR.txt" | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\t')
    if [ -z "$dkim_public_key" ]; then
        print_error "无法提取 DKIM 公钥，请检查 $DKIM_SELECTOR.txt"
        exit 1
    fi

    print_status "处理 DKIM TXT 记录..."
    local dkim_name="$DKIM_SELECTOR._domainkey.$MAIN_DOMAIN"
    response=$(cloudflare_api GET "zones/$ZONE_ID/dns_records?name=$dkim_name&type=TXT")
    if "$USE_JQ"; then
        record_id=$(echo "$response" | jq -r --arg dkim "$dkim_public_key" '.result[] | select(.content == $dkim) | .id // ""')
    else
        record_id=$(python3 -c "import json, os; data=json.loads(open(os.environ.get('TEMP_RESPONSE_FILE')).read()); print(next((r['id'] for r in data['result'] if r['content'] == os.environ.get('DKIM')), ''))" TEMP_RESPONSE_FILE="$TEMP_RESPONSE_FILE" DKIM="$dkim_public_key")
    fi
    local json_data=$(jq -n --arg name "$dkim_name" --arg content "$dkim_public_key" '{type: "TXT", name: $name, content: $content, ttl: 120}')
    if [ -n "$record_id" ]; then
        print_status "DKIM TXT 记录已存在，更新记录：$dkim_public_key"
        cloudflare_api PUT "zones/$ZONE_ID/dns_records/$record_id" "$json_data"
    else
        print_status "DKIM TXT 记录不存在，创建记录：$dkim_public_key"
        cloudflare_api POST "zones/$ZONE_ID/dns_records" "$json_data"
    fi

    generate_self_signed_cert
    configure_postfix
    configure_policyd
    configure_sasl
    configure_opendkim
    restart_all_services

    print_status "Postfix、OpenDKIM 和 Postfix Policyd 安装和配置完成！"
    print_status "请验证 Cloudflare DNS 记录是否已生效（dig $DOMAIN A; dig $DOMAIN MX; dig $DOMAIN TXT）。"
	
	# === 自动创建收件 catch-all 和常用邮件用户，并配置虚拟别名 ===

    VIRTUAL_FILE="/etc/postfix/virtual"
    DOMAIN_EMAIL="$DOMAIN"

    # 如果 /etc/postfix/virtual 不存在则创建
    if [ ! -f "$VIRTUAL_FILE" ]; then
        touch "$VIRTUAL_FILE"
    fi

# === 自动创建收件 catch-all 和常用邮件用户，并配置虚拟别名 ===

    for USER in "$SMTP_USER" "no-reply" "dmarc" "postmaster"; do
        if ! id "$USER" &>/dev/null; then
            useradd -m "$USER"
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

    postmap "$VIRTUAL_FILE"
    systemctl reload postfix
	
}

stop_all_services() {
    print_status "正在停止所有邮件服务..."
    service postfix stop || true
    service opendkim stop || true
    service saslauthd stop || true
    print_status "所有服务已停止。"
}

view_smtp_details() {
    if [ -z "$DOMAIN" ]; then
        print_error "请先运行安装脚本以设置域名和账户信息。"
        sleep 3
        return
    fi
    print_status "SMTP 账户信息："
    echo -e "IP 地址: ${GREEN}$EXTERNAL_IP${NC}"
    echo -e "IP 端口: ${GREEN}465 (SMTPS), 587 (STARTTLS)${NC}"
    echo -e "邮箱 地址: ${GREEN}no-reply@${DOMAIN}${NC}"
    if [ -f "$SCRIPT_DIR/smtp/credentials" ]; then
        local user=$(cut -d':' -f1 "$SCRIPT_DIR/smtp/credentials")
        local pass=$(cut -d':' -f2 "$SCRIPT_DIR/smtp/credentials")
        echo -e "SMTP 账号: ${GREEN}${user}@${DOMAIN}${NC}"
        echo -e "SMTP 密码: ${GREEN}$pass${NC}"
    else
        print_warning "未找到 SMTP 凭证文件，请先安装 Postfix。"
    fi
    read -p "按 Enter 继续..."
}

get_user_input() {
    print_status "正在执行初步检测..."
    check_json_parser

    if [ -f "$CONFIG_FILE" ]; then
        print_status "加载配置文件：$CONFIG_FILE"
        source "$CONFIG_FILE"
    fi

    if [ -z "$CLOUDFLARE_EMAIL" ]; then
        read -p "请输入您的 Cloudflare 邮箱: " CLOUDFLARE_EMAIL
    fi
    if [ -z "$CLOUDFLARE_API_KEY" ]; then
        read -p "请输入您的 Cloudflare API 密钥: " CLOUDFLARE_API_KEY
    fi
    if [ -z "$DOMAIN" ]; then
        read -p "请输入您的域名 (例如：example.com 或 sub.example.com): " DOMAIN
    fi

    validate_variable "CLOUDFLARE_EMAIL" "$CLOUDFLARE_EMAIL"
    validate_variable "CLOUDFLARE_API_KEY" "$CLOUDFLARE_API_KEY"
    validate_variable "DOMAIN" "$DOMAIN"

    if [ -z "$CLOUDFLARE_EMAIL" ] || [ -z "$CLOUDFLARE_API_KEY" ] || [ -z "$DOMAIN" ]; then
        print_error "Cloudflare 邮箱、API 密钥和域名不能为空。"
        exit 1
    fi

    cat > "$CONFIG_FILE" <<EOF
CLOUDFLARE_EMAIL="$CLOUDFLARE_EMAIL"
CLOUDFLARE_API_KEY="$CLOUDFLARE_API_KEY"
DOMAIN="$DOMAIN"
EOF
    chmod 600 "$CONFIG_FILE"

    get_external_ip
    get_zone_id

    # 动态设置 DKIM_SELECTOR
    if [ "$DOMAIN" = "$MAIN_DOMAIN" ]; then
        DKIM_SELECTOR="key"
    else
        DKIM_SELECTOR="${DOMAIN%.$MAIN_DOMAIN}"
    fi
    print_status "DKIM 选择器设置为：$DKIM_SELECTOR"

    hostnamectl set-hostname "$DOMAIN"
    print_status "主机名已设置为 $DOMAIN"
}

check_postfix_status() {
    if dpkg -s postfix >/dev/null 2>&1; then
        print_status "Postfix 已安装。"
        service postfix status | cat
    else
        print_warning "Postfix 未安装。"
    fi
    sleep 5
}

restart_all_services() {
    print_status "正在重启 OpenDKIM 服务..."
    service opendkim restart || true
    print_status "正在重启 saslauthd 服务..."
    service saslauthd restart || true
    print_status "正在重启 Postfix 服务..."
    service postfix restart || true
    print_status "所有服务已重启。"
    read -p "按 Enter 继续..."
}

view_queue() {
    print_status "正在查看 Postfix 队列..."
    mailq
    read -p "按 Enter 继续..."
}

flush_queue() {
    print_status "正在刷新 Postfix 队列..."
    postfix flush
    read -p "按 Enter 继续..."
}

delete_queue() {
    read -p "确定要删除所有 Postfix 队列邮件吗？(y/n) [Y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        print_status "正在删除所有 Postfix 队列邮件..."
        postsuper -d ALL
        print_status "队列已清空。正在重启服务..."
        service postfix restart
        service opendkim restart
        service saslauthd restart
        print_status "所有服务已重启。"
    else
        print_status "已取消删除队列。"
    fi
    read -p "按 Enter 继续..."
}

view_logs() {
    print_status "正在查看日志..."
    tail -n 100 "$LOG_FILE"
    read -p "按 Enter 继续..."
}

delete_logs() {
    read -p "确定要删除所有日志吗？(y/n) [Y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        print_status "正在删除日志..."
        rm -f "$LOG_FILE"
        print_status "日志已删除。"
        init_logs
    else
        print_status "已取消删除日志。"
    fi
    read -p "按 Enter 继续..."
}

show_main_menu() {
    echo "=== Postfix 管理脚本 ==="
    echo "1. 安装/卸载所有邮件服务"
    echo "2. Postfix 管理"
    echo "3. Postfix 队列管理"
    echo "4. Postfix 日志管理"
    echo "5. 退出"
    echo "========================="
}

main() {
    init_logs
    get_user_input

    while true; do
        clear
        show_main_menu
        read -p "输入选择: " choice
        case $choice in
            1)
                install_uninstall_menu
                ;;
            2)
                postfix_management_menu
                ;;
            3)
                queue_management_menu
                ;;
            4)
                log_management_menu
                ;;
            5)
                print_status "退出脚本。"
                exit 0
                ;;
            *)
                print_error "无效选择，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

install_uninstall_menu() {
    while true; do
        clear
        echo "=== 安装/卸载 ==="
        echo "1. 安装 Postfix、DKIM 和 Policyd Saslauthd .."
        echo "2. 卸载所有相关邮件服务"
        echo "3. 查看 Postfix 状态"
        echo "q. 返回主菜单"
        echo "========================"
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
        echo "=== Postfix 管理 ==="
        echo "1. 重启所有服务"
        echo "2. 查看 main.cf 配置"
        echo "3. 查看 DKIM 密钥文件"
        echo "4. 查看 Postfix Policyd 配置"
        echo "5. 查看 SMTP 账户信息"
        echo "q. 返回主菜单"
        echo "====================="
        read -p "输入选择: " choice
        case $choice in
            1) restart_all_services ;;
            2) print_status "正在显示 main.cf 配置..." ; cat /etc/postfix/main.cf ; read -p "按 Enter 继续..." ;;
            3) print_status "正在显示 DKIM 公钥..." ; cat /etc/dkimkeys/$MAIN_DOMAIN/$DKIM_SELECTOR.txt ; read -p "按 Enter 继续..." ;;
            4) print_status "正在显示 Postfix Policyd 配置..." ; cat /etc/postfix/master.cf | grep 'policy-spf' ; read -p "按 Enter 继续..." ;;
            5) view_smtp_details ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

queue_management_menu() {
    while true; do
        clear
        echo "=== Postfix 队列管理 ==="
        echo "1. 查看队列"
        echo "2. 刷新队列"
        echo "3. 删除所有队列邮件"
        echo "4. 查看成功日志 (status=sent)"
        echo "5. 查看成功收件人列表"
        echo "6. 查看退信 (bounced)"
        echo "7. 查看拒绝 (reject)"
        echo "8. 查看 SPF 拦截"
        echo "9. 清空 /var/log/mail.log"
        echo "q. 返回主菜单"
        echo "======================="
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
                    cat /dev/null > /var/log/mail.log
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
        echo "=== Postfix 日志管理 ==="
        echo "1. 查看脚本日志"
        echo "2. 删除日志"
        echo "q. 返回主菜单"
        echo "======================="
        read -p "输入选择: " choice
        case $choice in
            1) view_logs ;;
            2) delete_logs ;;
            q|Q) return ;;
            *) print_error "无效选择。" ; sleep 1 ;;
        esac
    done
}

main
