#!/bin/bash

# ==============================================================================
# SSH 终极安全加固脚本 (仅密钥登录，静默模式)
# 功能:
# 1. 禁用 root 密码登录功能 (锁定账户密码)
# 2. 配置 root 的 SSH 公钥作为唯一登录方式
# 3. 强制 SSH 服务只接受密钥认证，完全禁止密码认证
# 4. 隐藏所有过程性输出，除非出错
# ==============================================================================

# --- 配置变量 ---
# 你的公钥 (这是唯一的入口，请确保无误)
PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD2X571eCyO2O9wdX/aT/oZL+ZNG1/jd2u7u9LslKeiy8x1AFTM95xjqq7DEBJZ8X1f8e/Td7d5XY/c1v/1WP40ehEGLVMSJ5nNmPgQpcFETFKRrvWptdjJ20rppynlRHBpocLN4oRJ13RkrPCyZKs+7a53xBujH9QjQv3UF558oCN61WGJd1//wSIhEqIYELfjN7dNzujg1wBpZ4ACzkiqgZdu6vMw7cIihF8EMXKCtIJbAGB7yYQSgmKeKnUES9ZeUhc7lfYQWIgeuaVpNzKGxt767AGVwT8UO+6LZWGh9C7tD8RDqGtWwWJYcmOGr393Q7jR0CurJBQVMHpnROZ5 ssh-key-2022-11-08"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

# --- 函数定义 ---
# 错误处理函数
handle_error() {
    echo "错误：$1" >&2
    # 如果备份文件存在，尝试恢复
    if [ -f "$BACKUP_FILE" ]; then
        echo "正在尝试从备份 ${BACKUP_FILE} 恢复..." >&2
        mv "${BACKUP_FILE}" "${SSHD_CONFIG_FILE}"
        # 尝试重启服务以恢复访问
        if command -v systemctl &> /dev/null; then
            systemctl restart sshd
        else
            service ssh restart || service sshd restart
        fi
    fi
    exit 1
}

# --- 脚本开始 ---

# 检查是否以 root 身份运行
if [[ $EUID -ne 0 ]]; then
   handle_error "此脚本必须以 root 身份运行。"
fi

# 步骤 1: 锁定 root 账户的密码功能
# -l 选项会锁定账户密码，使其无法通过密码登录，比设置一个空密码更安全。
passwd -l root &> /dev/null || handle_error "锁定 root 密码失败。"

# 步骤 2: 配置 root 的 SSH 公钥
# 使用 >/dev/null 2>&1 来抑制所有输出
{
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh
} &> /dev/null || handle_error "配置 root 公钥失败。"

# 步骤 3: 修改 SSHD 配置文件
BACKUP_FILE="${SSHD_CONFIG_FILE}.bak_$(date +%s)"
cp "${SSHD_CONFIG_FILE}" "${BACKUP_FILE}" &> /dev/null || handle_error "创建备份文件失败。"

# 从现有配置中提取当前端口号
CURRENT_PORT=$(grep -i '^Port' "${BACKUP_FILE}" | awk '{print $2}' | tail -n 1)
[ -z "${CURRENT_PORT}" ] && CURRENT_PORT="22"

# 创建新的 sshd_config 文件
cat > "${SSHD_CONFIG_FILE}" << EOF
# ===============================================================
# 此配置文件由安全脚本自动生成 (仅限密钥登录)
# 原始文件备份于: ${BACKUP_FILE}
# ===============================================================

Port ${CURRENT_PORT}
Protocol 2

# --- 认证核心配置 (最高安全级别) ---

# 启用公钥认证
PubkeyAuthentication yes

# 严格禁止所有形式的密码/交互式认证
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# --- 其他安全加固 ---

# 允许 root 登录，但仅能通过密钥
PermitRootLogin prohibit-password

# 禁止空密码登录 (双重保险)
PermitEmptyPasswords no

# 限制认证尝试次数
MaxAuthTries 3

# 缩短登录宽限时间
LoginGraceTime 30s

# 禁用 X11 转发
X11Forwarding no

# 自动断开空闲连接
ClientAliveInterval 300
ClientAliveCountMax 2

# --- 标准设置 ---
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePAM yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

EOF

# 步骤 4: 验证配置并重启 SSH 服务
sshd -t &> /dev/null || handle_error "新的 SSH 配置语法不正确！"

# 重启 SSH 服务
{
    if command -v systemctl &> /dev/null; then
        systemctl restart sshd
    else
        service ssh restart || service sshd restart
    fi
} &> /dev/null || handle_error "重启 SSH 服务失败。"

# 如果所有步骤都成功，则显示最终信息
echo "### ✅ 配置完成！ ###"

exit 0
