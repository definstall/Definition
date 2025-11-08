#!/bin/bash

# ==============================================================================
# 脚本名称: upgrade_ubuntu.sh
# 描述: 检查当前 Ubuntu 版本，如果不是 22.04，则执行系统更新和升级到 22.04。
# 注意: 在执行此关键操作前，请务必备份重要数据！
# ==============================================================================

# 检查当前 Ubuntu 版本
CURRENT_VERSION=$(lsb_release -rs)
TARGET_VERSION="22.04"

echo "➡️ 当前系统版本是: Ubuntu $CURRENT_VERSION"

# 步骤 1: 检查版本
if [ "$CURRENT_VERSION" == "$TARGET_VERSION" ]; then
    echo "✅ 系统已经是 Ubuntu $TARGET_VERSION。跳过升级。"
    exit 0
fi

echo "---"
echo "⚠️ 系统版本不是 $TARGET_VERSION。开始升级到 Ubuntu $TARGET_VERSION..."
echo "---"

# 步骤 2: 首次系统更新和清理 (保持当前系统最新)
echo "🚀 2.1 首次系统更新、清理和准备必要的软件包..."
sudo apt update -y
sudo apt upgrade -y
sudo apt dist-upgrade -y
sudo apt autoclean
sudo apt autoremove -y

# 安装升级所需的依赖包
echo "📦 2.2 安装所需的依赖包..."
sudo apt update -y && \
sudo apt install -y curl socat wget xz-utils openssl gawk file

# 步骤 3: 修改 APT 源 (将 focal 替换为 jammy)
echo "📝 3. 修改 APT 源，将 'focal' 替换为 'jammy'..."
if grep -q "focal" /etc/apt/sources.list; then
    sudo sed -i 's/focal/jammy/g' /etc/apt/sources.list
    echo "   - /etc/apt/sources.list 中的源已替换为 'jammy'."
else
    echo "   - /etc/apt/sources.list 中未找到 'focal'，跳过替换。"
fi

# 替换 sources.list.d/ 目录下的文件
find /etc/apt/sources.list.d/ -type f -name "*.list" -print0 | while IFS= read -r -d $'\0' file; do
    if grep -q "focal" "$file"; then
        sudo sed -i 's/focal/jammy/g' "$file"
        echo "   - $file 中的源已替换为 'jammy'."
    fi
done

# 步骤 4: 执行升级
echo "🔄 4. 执行正式升级到 Ubuntu $TARGET_VERSION..."

echo "   - 4.1 再次更新 APT 索引..."
sudo apt update

echo "   - 4.2 执行主要升级 (apt upgrade)..."
sudo apt upgrade -y

echo "   - 4.3 执行分发版升级 (apt dist-upgrade)..."
# 注意: dist-upgrade 可能会询问配置问题，如果脚本无人值守运行，可能需要预先配置 debconf 或使用 -y 确保同意。
# 在这里，我们假设 -y 足够处理大多数情况。
sudo apt dist-upgrade -y

# 步骤 5: 清理和重启
echo "🧹 5. 清理不再需要的软件包..."
sudo apt autoclean
sudo apt autoremove -y

echo "🎉 升级完成！请手动重启系统以应用所有更改。"
echo "请执行 'sudo reboot' 完成升级过程。"
# 如果您希望脚本自动重启，可以将下一行解除注释 (不推荐在生产环境无人值守):
# sudo reboot
