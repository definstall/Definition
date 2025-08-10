#!/bin/bash

# ==============================================================================
# SSH 终极安全加固脚本 (交互式，非覆盖式配置修改，支持 XRDP root 密码登录)
# 功能:
# 1. 交互式询问是否配置 XRDP 专用用户，并拒绝其 SSH 登录。
# 2. 交互式询问是否允许 root 用户通过 XRDP 密码登录 (SSH 仍仅限密钥)。
#    如果允许，则自动设置 root 密码为固定值。
# 3. 配置 root 的 SSH 公钥作为唯一 SSH 登录方式。
# 4. 强制 SSH 服务只接受密钥认证，完全禁止密码认证。
# 5. 非覆盖式修改 sshd_config，保留现有配置，仅修改或添加指定安全项。
# 6. 隐藏所有过程性输出，除非出错。
# ==============================================================================

# --- 配置变量 ---
# 你的公钥 (这是唯一的入口，请确保无误)
PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD2X571eCyO2O9wdX/aT/oZL+ZNG1/jd2u7u9LslKeiy8x1AFTM95xjqq7DEBJZ8X1f8e/Td7d5XY/c1v/1WP40ehEGLVMSJ5nNmPgQpcFETFKRrvWptdjJ20rppynlRHBpocLN4oRJ13RkrPCyZKs+7a53xBujH9QjQv3UF558oCN61WGJd1//wSIhEqIYELfjN7dNzujg1wBpZ4ACzkiqgZdu6vMw7cIihF8EMXKCtIJbAGB7yYQSgmKeKnUES9ZeUhc7lfYQWIgeuaVpNzKGxt767AGVwT8UO+6LZWGh9C7tD8RDqGtWwWJYcmOGr393Q7jR0CurJBQVMHpnROZ5 ssh-key-2022-11-08"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
BACKUP_FILE="${SSHD_CONFIG_FILE}.bak_$(date +%s)"

# XRDP 用户配置
XRDP_USER_NAME="ubuntu"
XRDP_USER_PASS="AnuBiC_s6" # 警告：硬编码密码不推荐用于生产环境，请考虑更安全的密码管理方式。
                           # 强烈建议在脚本执行后立即修改此密码！

# 内部标志，根据用户选择设置
CREATE_XRDP_USER=false
ALLOW_ROOT_XRDP_LOGIN=false

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
            systemctl restart sshd &> /dev/null
        else
            service ssh restart &> /dev/null || service sshd restart &> /dev/null
        fi
    fi
    exit 1
}

# 函数：设置或更新 sshd_config 中的参数
# 如果参数存在（无论是否注释），则更新其值并取消注释。
# 如果参数不存在，则添加到文件末尾。
# Usage: set_sshd_config_param "ParameterName" "Value"
set_sshd_config_param() {
    local param="$1"
    local value="$2"
    local config_file="$SSHD_CONFIG_FILE"

    # Escape value for sed to handle special characters like / &
    local escaped_value=$(echo "$value" | sed 's/[\/&]/\\&/g')

    # Check if the parameter exists (active or commented out)
    if grep -qE "^#?\s*${param}\s+" "$config_file"; then
        # Parameter exists, update it and ensure it's not commented
        # Use a temporary file for sed to avoid issues with in-place editing
        sed -i.bak_tmp -E "s/^#?\s*(${param})\s+.*$/\1 ${escaped_value}/" "$config_file"
        rm "${config_file}.bak_tmp" # Clean up sed's temporary backup
        echo "  - 已更新/设置: ${param} ${value}"
    else
        # Parameter does not exist, add it to the end of the file
        echo "${param} ${value}" >> "$config_file"
        echo "  - 已添加: ${param} ${value}"
    fi
}

# 函数：向 DenyUsers 列表添加用户
add_to_denyusers() {
    local user_to_deny="$1"
    local config_file="$SSHD_CONFIG_FILE"

    if grep -qE "^#?\s*DenyUsers\s+" "$config_file"; then
        # DenyUsers line exists
        if ! grep -qE "^#?\s*DenyUsers\s+.*\b${user_to_deny}\b.*" "$config_file"; then
            # User not in DenyUsers, append it
            sed -i.bak_tmp -E "s/^#?\s*(DenyUsers\s+.*)$/\1 ${user_to_deny}/" "$config_file"
            rm "${config_file}.bak_tmp"
            echo "  - 已添加到 DenyUsers: ${user_to_deny}"
        else
            echo "  - ${user_to_deny} 已在 DenyUsers 列表中。"
        fi
    else
        # DenyUsers line does not exist, add it
        echo "DenyUsers ${user_to_deny}" >> "$config_file"
        echo "  - 已添加 DenyUsers: ${user_to_deny}"
    fi
}

# --- 脚本开始 ---

echo "=============================================================================="
echo "                 SSH 终极安全加固脚本 (交互式)"
echo "=============================================================================="

# 检查是否以 root 身份运行
if [[ $EUID -ne 0 ]]; then
   handle_error "此脚本必须以 root 身份运行。"
fi

# 步骤 0: 交互式询问 XRDP 配置
echo ""
read -p "您的服务器是否安装了 XRDP (远程桌面) 服务？(y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "好的，检测到 XRDP 服务。"
    read -p "是否需要允许 'root' 用户通过 XRDP 使用密码登录？(y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ALLOW_ROOT_XRDP_LOGIN=true
        echo "好的，将允许 root 用户通过 XRDP 密码登录。"
        echo "警告：SSH 仍将禁止 root 密码登录，但 root 密码将保持活跃。"
        echo "      root 密码将被设置为 '${XRDP_USER_PASS}'。"
        echo "      请务必在脚本执行后立即修改 root 密码以增强安全性！"
    else
        echo "好的，root 密码将保持锁定，无法通过 XRDP 密码登录。"
    fi

    read -p "是否需要为 XRDP 创建一个专用用户 '${XRDP_USER_NAME}' 并拒绝其 SSH 登录？(y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        CREATE_XRDP_USER=true
        echo "好的，将创建 XRDP 专用用户 '${XRDP_USER_NAME}'。"
        echo "警告：该用户的密码将固定为 '${XRDP_USER_PASS}'。"
        echo "      请务必在脚本执行后修改此密码以增强安全性！"
    else
        echo "好的，跳过 XRDP 专用用户创建。"
    fi
else
    echo "好的，跳过 XRDP 相关配置。"
fi

echo ""
echo "--- 开始执行安全加固 ---"

# 步骤 1: 根据用户选择处理 root 账户密码
if [ "${ALLOW_ROOT_XRDP_LOGIN}" = "true" ]; then
    echo "1. 正在设置 root 账户密码为 '${XRDP_USER_PASS}' (用于 XRDP 等服务)..."
    # chpasswd 会自动解锁密码并设置新密码
    echo "root:${XRDP_USER_PASS}" | chpasswd &> /dev/null || handle_error "设置 root 密码失败。"
    echo "   ✅ root 密码已设置。请务必在脚本执行后立即修改！"
else
    echo "1. 正在锁定 root 账户密码功能..."
    passwd -l root &> /dev/null || handle_error "锁定 root 密码失败。"
    echo "   ✅ root 密码已锁定 (无法通过密码登录)。"
fi

# 步骤 2: 配置 root 的 SSH 公钥
echo "2. 正在配置 root 的 SSH 公钥..."
{
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh
} &> /dev/null || handle_error "配置 root 公钥失败。"
echo "   ✅ root SSH 公钥已配置。"

# 步骤 3: 修改 SSHD 配置文件
echo "3. 正在修改 SSHD 配置文件 (${SSHD_CONFIG_FILE})..."

# 创建备份文件
cp "${SSHD_CONFIG_FILE}" "${BACKUP_FILE}" &> /dev/null || handle_error "创建备份文件失败。"
echo "   ✅ 原始配置文件已备份至: ${BACKUP_FILE}"

# 从现有配置中提取当前端口号，如果不存在则默认为 22
CURRENT_PORT=$(grep -i '^Port' "${SSHD_CONFIG_FILE}" | awk '{print $2}' | tail -n 1)
[ -z "${CURRENT_PORT}" ] && CURRENT_PORT="22"
echo "   - 检测到当前 SSH 端口为: ${CURRENT_PORT}"

echo "   - 正在应用安全配置项..."
set_sshd_config_param "Port" "${CURRENT_PORT}"
set_sshd_config_param "Protocol" "2"
set_sshd_config_param "PubkeyAuthentication" "yes"
set_sshd_config_param "PasswordAuthentication" "no" # 强制 SSH 不接受密码登录 (对所有用户生效)
set_sshd_config_param "KbdInteractiveAuthentication" "no"
set_sshd_config_param "ChallengeResponseAuthentication" "no"
set_sshd_config_param "PermitRootLogin" "prohibit-password" # 允许 root SSH 登录，但仅限密钥
set_sshd_config_param "PermitEmptyPasswords" "no"
set_sshd_config_param "MaxAuthTries" "3"
set_sshd_config_param "LoginGraceTime" "30s"
set_sshd_config_param "X11Forwarding" "no"
set_sshd_config_param "ClientAliveInterval" "300"
set_sshd_config_param "ClientAliveCountMax" "2"
set_sshd_config_param "UsePAM" "yes"
set_sshd_config_param "PrintMotd" "no"
set_sshd_config_param "AcceptEnv" "LANG LC_*"
set_sshd_config_param "Subsystem" "sftp /usr/lib/openssh/sftp-server"

# 如果需要创建 XRDP 专用用户，则创建并添加到 DenyUsers
if [ "${CREATE_XRDP_USER}" = "true" ]; then
    echo "4. 正在创建 XRDP 专用用户 '${XRDP_USER_NAME}'..."
    if id "${XRDP_USER_NAME}" &>/dev/null; then
        echo "   - 用户 '${XRDP_USER_NAME}' 已存在，跳过创建。"
    else
        # 使用 adduser 更友好，会自动创建家目录和设置默认shell
        # --disabled-password 避免交互式密码提示
        # --gecos "" 避免交互式用户信息提示
        adduser --disabled-password --gecos "" "${XRDP_USER_NAME}" &> /dev/null || handle_error "创建 XRDP 用户失败。"
        echo "${XRDP_USER_NAME}:${XRDP_USER_PASS}" | chpasswd &> /dev/null || handle_error "设置 XRDP 用户密码失败。"
        echo "   ✅ 用户 '${XRDP_USER_NAME}' 已创建，密码为 '${XRDP_USER_PASS}'。"
        echo "   请务必在 XRDP 登录后立即修改此密码！"
    fi
    echo "   - 正在将 '${XRDP_USER_NAME}' 添加到 SSH DenyUsers 列表..."
    add_to_denyusers "${XRDP_USER_NAME}"
fi

echo "   ✅ SSHD 配置文件修改完成。"

# 步骤 5: 验证配置并重启 SSH 服务
echo "5. 正在验证新的 SSH 配置语法..."
sshd -t &> /dev/null || handle_error "新的 SSH 配置语法不正确！请检查 ${SSHD_CONFIG_FILE}。"
echo "   ✅ SSH 配置语法验证通过。"

echo "6. 正在重启 SSH 服务..."
{
    if command -v systemctl &> /dev/null; then
        systemctl restart sshd &> /dev/null
    else
        service ssh restart &> /dev/null || service sshd restart &> /dev/null
    fi
} &> /dev/null || handle_error "重启 SSH 服务失败。请手动检查服务状态。"
echo "   ✅ SSH 服务已重启。"

echo ""
echo "=============================================================================="
echo "### ✅ SSH 安全配置完成！ ###"
echo "请使用您的 SSH 密钥登录 root 用户。"
if [ "${ALLOW_ROOT_XRDP_LOGIN}" = "true" ]; then
    echo "root 用户的密码已设置为 '${XRDP_USER_PASS}'，您可以使用它通过 XRDP 远程桌面登录。"
    echo "请务必在脚本执行后立即修改 root 密码！"
fi
if [ "${CREATE_XRDP_USER}" = "true" ]; then
    echo "XRDP 专用用户 '${XRDP_USER_NAME}' 已创建，密码为 '${XRDP_USER_PASS}'。"
    echo "您也可以使用此用户通过 XRDP 远程桌面登录。"
    echo "请务必在首次 XRDP 登录后修改 '${XRDP_USER_NAME}' 的密码！"
fi
echo "=============================================================================="

exit 0
