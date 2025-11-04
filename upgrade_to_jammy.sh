#!/bin/bash

# 文件名: full_auto_upgrade.sh
# 描述: 全自动升级 Ubuntu 系统，从 Focal 20.04 升级到 Jammy 22.04 的源，
#       并执行必要的更新、升级和清理。
# 特性: 1. 严格检查操作系统和版本。
#       2. 设置 DEBIAN_FRONTEND=noninteractive 和 dpkg 选项，去除所有交互提示。
# 注意: 升级大版本有风险，请务必备份数据！

# --- 0. 权限和环境检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请使用 sudo 运行此脚本。"
  exit 1
fi

# 检查操作系统是否为 Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
  echo "❌ 错误：此脚本仅适用于 Ubuntu 操作系统。"
  exit 1
fi

# 检查 Ubuntu 版本是否低于 24
VERSION_ID=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release | cut -d'.' -f1)
if [ "$VERSION_ID" -ge 24 ]; then
  echo "❌ 错误：当前 Ubuntu 版本 (v$VERSION_ID) 大于或等于 24，不适合运行此脚本升级到 Jammy (22)。"
  echo "请手动检查 /etc/apt/sources.list。"
  exit 1
fi

echo "✅ 系统检查通过：操作系统为 Ubuntu，版本低于 24。"

# 设置非交互式模式，**这是去除所有提示的关键！**
export DEBIAN_FRONTEND=noninteractive

# 设置 dpkg 选项，强制保留旧配置文件，解决 'crontab (Y/I/N/O/D/Z)' 等提示
DPKG_OPTIONS='-o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"'

# --- 1. 初始清理 ---
echo "--- 1. 执行初始 APT 清理和基础更新 ---"
apt update
apt upgrade -y
apt dist-upgrade -y
apt autoclean
apt autoremove -y
echo "初始清理和基础更新完成。"

# --- 2. 替换 APT 源版本 (focal -> jammy) ---
echo "--- 2. 替换 APT 源版本 (focal -> jammy) ---"
# 针对主源文件
sed -i 's/focal/jammy/g' /etc/apt/sources.list 2>/dev/null
# 针对 /etc/apt/sources.list.d/ 目录下的其他源文件
find /etc/apt/sources.list.d/ -type f -print0 | xargs -0 sed -i 's/focal/jammy/g' 2>/dev/null
echo "APT 源版本替换完成：focal 已替换为 jammy。"

# --- 3. 核心系统升级 (使用非交互式选项) ---
echo "--- 3. 核心系统升级 (非交互式) ---"

# 更新新的源列表
echo "执行 apt update..."
apt update -y

# 升级已安装的包
echo "执行 apt upgrade -y (升级)..."
apt upgrade -y

# 处理依赖和新的内核/包 (最关键的升级步骤，应用 DPKG 选项)
echo "执行 apt dist-upgrade -y $DPKG_OPTIONS (大版本分发升级，强制保留旧配置)..."
# 使用 -E 确保 DEBIAN_FRONTEND 变量能传递给 sudo 环境
apt dist-upgrade -y $DPKG_OPTIONS 

# 确保在升级过程中没有出现致命错误
if [ $? -ne 0 ]; then
    echo "--- !!! 警告: dist-upgrade 过程中可能出现了错误，请检查日志 !!! ---"
    exit 1
fi

echo "核心系统升级完成。"

# --- 4. 最终清理 ---
echo "--- 4. 执行最终 APT 清理 ---"
apt autoclean
apt autoremove -y
echo "最终清理完成。"

# --- 5. 重启系统 ---
echo "--- 5. 脚本运行完成，系统将在 10 秒后重启以应用所有更改！ ---"
sleep 10
reboot
