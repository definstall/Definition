#!/bin/bash

# 文件名: auto_lts_upgrade.sh
# 描述: 全自动将 Ubuntu LTS 版本升级到下一个 LTS 版本。
# 特性: 1. 严格检查操作系统。
#       2. 根据当前版本自动确定升级目标。
#       3. 设置非交互式模式，去除所有图形化和配置文件提示。
# 注意: 升级大版本有风险，请务必备份数据！

# --- 0. 配置 LTS 版本映射 ---
declare -A LTS_MAP
LTS_MAP["focal"]="jammy"   # 20.04 -> 22.04
LTS_MAP["jammy"]="noble"   # 22.04 -> 24.04
# 如果未来有新版本，只需在此处添加：
# LTS_MAP["noble"]="oracular" # 24.04 -> 26.04

# 设置非交互式模式和 DPKG 选项 (去除所有提示的关键)
export DEBIAN_FRONTEND=noninteractive
DPKG_OPTIONS='-o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"'

# --- 1. 权限和环境检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 sudo 运行此脚本。"
  exit 1
fi

# 检查操作系统是否为 Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
  echo "❌ 错误：此脚本仅适用于 Ubuntu 操作系统。"
  exit 1
fi

# 获取当前代号
CURRENT_CODENAME=$(grep -oP 'VERSION_CODENAME=\K[^"]+' /etc/os-release)
OLD_CODENAME="$CURRENT_CODENAME"

# 确定目标代号
NEW_CODENAME=${LTS_MAP[$OLD_CODENAME]}

# 检查是否支持升级目标
if [ -z "$NEW_CODENAME" ]; then
  echo "❌ 错误：当前 Ubuntu 代号 ($OLD_CODENAME) 不支持通过此脚本升级到下一个 LTS 版本。"
  echo "请确保你在 LTS 版本 (如 focal 或 jammy) 上运行，并检查 LTS_MAP 是否已更新。"
  exit 1
fi

echo "✅ 系统检查通过：当前为 Ubuntu $OLD_CODENAME，将升级到 $NEW_CODENAME。"

# --- 2. 初始清理和基础更新 (使用非交互式选项) ---
echo "--- 2. 执行初始 APT 清理和基础更新 ---"
apt update
apt upgrade -y $DPKG_OPTIONS
apt dist-upgrade -y $DPKG_OPTIONS
apt autoclean
apt autoremove -y
echo "初始清理和基础更新完成。"

# --- 3. 替换 APT 源版本 ---
echo "--- 3. 替换 APT 源版本 ($OLD_CODENAME -> $NEW_CODENAME) ---"
# 使用 sed 动态替换当前代号为目标代号
# 针对主源文件
sed -i "s/$OLD_CODENAME/$NEW_CODENAME/g" /etc/apt/sources.list 2>/dev/null
# 针对 /etc/apt/sources.list.d/ 目录下的其他源文件
find /etc/apt/sources.list.d/ -type f -print0 | xargs -0 sed -i "s/$OLD_CODENAME/$NEW_CODENAME/g" 2>/dev/null
echo "APT 源版本替换完成：$OLD_CODENAME 已替换为 $NEW_CODENAME。"

# --- 4. 核心系统升级 (使用非交互式选项) ---
echo "--- 4. 核心系统升级 (非交互式) ---"

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

# --- 5. 最终清理 ---
echo "--- 5. 执行最终 APT 清理 ---"
apt autoclean
apt autoremove -y
echo "最终清理完成。"

# --- 6. 重启系统 ---
echo "--- 6. 脚本运行完成，系统将在 10 秒后重启以应用所有更改！ ---"
sleep 10
reboot
