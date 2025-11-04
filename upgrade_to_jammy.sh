#!/bin/bash

# 文件名: upgrade_to_jammy.sh
# 描述: 全自动升级 Ubuntu 系统，从 Focal 20.04 升级到 Jammy 22.04 的源，
#       并执行必要的更新、升级和清理。
# 注意: 升级大版本有风险，请务必备份数据！

# --- 1. 初始清理 ---
echo "--- 1. 执行初始 APT 清理 ---"
apt update
apt upgrade -y
apt dist-upgrade -y
apt autoclean
apt autoremove -y
echo "初始清理和基础更新完成。"

# --- 2. 替换 APT 源版本 (focal -> jammy) ---
echo "--- 2. 替换 APT 源版本 (focal -> jammy) ---"
# 使用 sed 命令进行非交互式替换，忽略错误以防某些文件不存在
# 针对主源文件
sed -i 's/focal/jammy/g' /etc/apt/sources.list 2>/dev/null
# 针对 /etc/apt/sources.list.d/ 目录下的其他源文件
find /etc/apt/sources.list.d/ -type f -print0 | xargs -0 sed -i 's/focal/jammy/g' 2>/dev/null
echo "APT 源版本替换完成：focal 已替换为 jammy。"

# --- 3. 核心系统升级 ---
echo "--- 3. 核心系统升级 ---"

# 设置 DEBIAN_FRONTEND=noninteractive 以确保所有操作都是非交互式的 (去除图形化和提问)
export DEBIAN_FRONTEND=noninteractive

# 更新新的源列表
echo "执行 apt update..."
apt update -y

# 升级已安装的包
echo "执行 apt upgrade -y (升级)..."
apt upgrade -y

# 处理依赖和新的内核/包 (最关键的升级步骤)
echo "执行 apt dist-upgrade -y (大版本分发升级)..."
apt dist-upgrade -y

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
echo "--- 5. 脚本运行完成，系统将在 10 秒后重启！ ---"
sleep 5
reboot
