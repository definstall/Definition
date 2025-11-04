#!/bin/bash

# 文件名: ultimate_lts_upgrade.sh
# 描述: 健壮型全自动 Ubuntu LTS 版本升级脚本。
# 功能: 1. 自动修复 DPKG 数据库错误。
#       2. 根据当前版本自动确定升级目标 (20.04->22.04, 22.04->24.04)。
#       3. 全程非交互式，去除所有提示。

# --- 0. 配置变量和映射 ---
declare -A LTS_MAP
LTS_MAP["focal"]="jammy"   # 20.04 -> 22.04
LTS_MAP["jammy"]="noble"   # 22.04 -> 24.04

# 设置非交互式模式 (去除大部分提示)
export DEBIAN_FRONTEND=noninteractive
# 设置 DPKG 选项 (强制保留旧配置，去除配置文件交互提示)
DPKG_OPTIONS='-o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"'

# --- 1. 权限和系统环境检查 ---
echo "--- 1. 执行权限和系统环境检查 ---"

if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 sudo 运行此脚本。"
  exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release; then
  echo "❌ 错误：此脚本仅适用于 Ubuntu 操作系统。"
  exit 1
fi

# 获取当前代号并确定目标代号
CURRENT_CODENAME=$(grep -oP 'VERSION_CODENAME=\K[^"]+' /etc/os-release)
OLD_CODENAME="$CURRENT_CODENAME"
NEW_CODENAME=${LTS_MAP[$OLD_CODENAME]}

if [ -z "$NEW_CODENAME" ]; then
  echo "❌ 错误：当前 Ubuntu 代号 ($OLD_CODENAME) 不支持通过此脚本升级到下一个 LTS 版本。"
  echo "请确保你在 LTS 版本 (如 focal 或 jammy) 上运行，并检查 LTS_MAP 是否已更新。"
  exit 1
fi

echo "✅ 系统检查通过：当前为 Ubuntu $OLD_CODENAME，目标升级到 $NEW_CODENAME。"

# --- 2. DPKG 数据库和状态修复 ---
echo "--- 2. 尝试修复 DPKG 数据库和状态文件 ---"

# 2.1 尝试修复半安装的包和依赖
echo "尝试修复 dpkg 数据库 (--configure -a) 和依赖 (-f)..."
dpkg --configure -a
apt install -f -y
# 忽略这里的返回码，确保流程继续。

# 2.2 检查并修复 /var/lib/dpkg/status 文件末尾的空行
STATUS_FILE="/var/lib/dpkg/status"
if [ -f "$STATUS_FILE" ]; then
    # 检查最后一行是否为空行
    if [[ $(tail -n 1 "$STATUS_FILE" | wc -l) -eq 1 && -z $(tail -n 1 "$STATUS_FILE") ]]; then
        echo "DPKG 状态文件末尾有空行，状态良好。"
    else
        echo "DPKG 状态文件末尾缺少空行。正在自动添加..."
        cp "$STATUS_FILE" "$STATUS_FILE.bak.$(date +%Y%m%d%H%M%S)"
        echo "" | tee -a "$STATUS_FILE" > /dev/null
        echo "DPKG 状态文件修复完成。备份文件已创建。"
    fi
else
    echo "❌ 警告: $STATUS_FILE 文件不存在，无法进行状态修复。"
fi

# --- 3. 初始清理和基础更新 (使用 DPKG 选项确保非交互) ---
echo "--- 3. 执行初始 APT 清理和基础更新 ---"
apt update
# *** 优化点：使用 DPKG_OPTIONS 确保初始更新也非交互式 ***
apt upgrade -y $DPKG_OPTIONS
apt dist-upgrade -y $DPKG_OPTIONS
apt autoclean
apt autoremove -y
echo "初始清理和基础更新完成。"

# --- 4. 替换 APT 源版本 ---
echo "--- 4. 替换 APT 源版本 ($OLD_CODENAME -> $NEW_CODENAME) ---"
# 针对主源文件
sed -i "s/$OLD_CODENAME/$NEW_CODENAME/g" /etc/apt/sources.list 2>/dev/null
# 针对 /etc/apt/sources.list.d/ 目录下的其他源文件
find /etc/apt/sources.list.d/ -type f -print0 | xargs -0 sed -i "s/$OLD_CODENAME/$NEW_CODENAME/g" 2>/dev/null
echo "APT 源版本替换完成：$OLD_CODENAME 已替换为 $NEW_CODENAME。"

# --- 5. 核心系统升级 (非交互式) ---
echo "--- 5. 核心系统升级 (非交互式) ---"

# 更新新的源列表
echo "执行 apt update..."
apt update -y

# 升级已安装的包
echo "执行 apt upgrade -y (升级)..."
apt upgrade -y $DPKG_OPTIONS

# 处理依赖和新的内核/包 (最关键的升级步骤)
echo "执行 apt dist-upgrade -y $DPKG_OPTIONS (大版本分发升级)..."
apt dist-upgrade -y $DPKG_OPTIONS 

# 确保在升级过程中没有出现致命错误
if [ $? -ne 0 ]; then
    echo "--- !!! 警告: dist-upgrade 过程中可能出现了错误，请检查日志 !!! ---"
    exit 1
fi

echo "核心系统升级完成。"

# --- 6. 最终清理 ---
echo "--- 6. 执行最终 APT 清理 ---"
apt autoclean
apt autoremove -y
echo "最终清理完成。"

# --- 7. 重启系统 ---
echo "--- 7. 脚本运行完成，系统将在 10 秒后重启以应用所有更改！ ---"
sleep 10
reboot
