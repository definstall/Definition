#!/usr/bin/env bash

set -u
set -o pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly MIRROR_URL="http://mirrors.163.com/ubuntu"
readonly TARGET_22_04="22.04"
readonly TARGET_24_04="24.04"
readonly TARGET_24_04_POINT="24.04.4"

if (( EUID == 0 )); then
    SUDO=()
else
    SUDO=(sudo)
fi

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

pause() {
    read -r -p "按回车继续..." _
}

confirm() {
    local prompt="${1:-确认继续吗? [y/N]: }"
    local answer

    read -r -p "$prompt" answer
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

ensure_privilege_escalation() {
    if (( EUID != 0 )) && ! command -v sudo >/dev/null 2>&1; then
        error "当前用户不是 root，且系统中未找到 sudo，无法继续执行需要提权的操作。"
        return 1
    fi
}

load_os_release() {
    if [[ ! -r /etc/os-release ]]; then
        error "无法读取 /etc/os-release，无法识别当前系统版本。"
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
    CURRENT_VERSION="${VERSION_ID:-unknown}"
    CURRENT_CODENAME="${VERSION_CODENAME:-}"
    PRETTY_OS_NAME="${PRETTY_NAME:-Ubuntu}"

    if [[ -z "$CURRENT_CODENAME" && -r /etc/lsb-release ]]; then
        # shellcheck disable=SC1091
        . /etc/lsb-release
        CURRENT_CODENAME="${DISTRIB_CODENAME:-}"
    fi

    if [[ -z "$CURRENT_CODENAME" ]]; then
        error "无法识别当前系统代号（如 focal/jammy/noble）。"
        return 1
    fi
}

ensure_ubuntu() {
    load_os_release || return 1

    if [[ "$OS_ID" != "ubuntu" && "$OS_ID_LIKE" != *ubuntu* ]]; then
        error "此脚本仅支持 Ubuntu 系统，当前检测到：${PRETTY_OS_NAME}"
        return 1
    fi
}

backup_file() {
    local file="$1"
    local timestamp
    local backup

    if [[ ! -e "$file" ]]; then
        return 0
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup="${file}.${timestamp}.bak"

    "${SUDO[@]}" cp -a "$file" "$backup"
    info "已备份：$file -> $backup"
}

disable_file_with_backup() {
    local file="$1"
    local timestamp
    local disabled

    if [[ ! -e "$file" ]]; then
        return 0
    fi

    timestamp="$(date +%Y%m%d-%H%M%S)"
    disabled="${file}.${timestamp}.disabled"

    "${SUDO[@]}" mv "$file" "$disabled"
    info "已禁用：$file -> $disabled"
}

refresh_package_lists() {
    "${SUDO[@]}" apt-get update
}

upgrade_current_release_packages() {
    refresh_package_lists || return 1
    "${SUDO[@]}" apt-get upgrade -y || return 1
    "${SUDO[@]}" apt-get dist-upgrade -y -o APT::Get::Always-Include-Phased-Updates=true || return 1
    "${SUDO[@]}" apt-get autoremove -y || return 1
    "${SUDO[@]}" apt-get autoclean || return 1
}

show_current_system() {
    ensure_ubuntu || return 1
    info "当前系统：${PRETTY_OS_NAME}（版本 ${CURRENT_VERSION}，代号 ${CURRENT_CODENAME}）"
}

check_kubuntu() {
    ensure_ubuntu || return 1

    info "检测 Kubuntu 桌面是否已安装..."
    if dpkg-query -W -f='${Status}' kubuntu-desktop 2>/dev/null | grep -q '^install ok installed$'; then
        info "Kubuntu 桌面已经安装。"
        return 0
    fi

    warn "Kubuntu 桌面未安装。"
    if confirm "是否现在安装 Kubuntu 桌面? [y/N]: "; then
        install_kubuntu
    else
        info "已取消安装。"
    fi
}

install_kubuntu() {
    ensure_ubuntu || return 1
    ensure_privilege_escalation || return 1

    warn "此操作会安装 KDE / Kubuntu 桌面环境，并可能提示你选择显示管理器。"
    if ! confirm "确认继续安装 Kubuntu 桌面? [y/N]: "; then
        info "已取消安装。"
        return 0
    fi

    refresh_package_lists || return 1
    "${SUDO[@]}" apt-get install -y kubuntu-desktop dolphin sddm || return 1

    warn "Kubuntu 桌面安装完成，建议手动重启系统。"
}

install_chinese_language() {
    ensure_ubuntu || return 1
    ensure_privilege_escalation || return 1

    info "开始安装中文语言支持..."

    local packages=(
        language-pack-zh-hans
        language-pack-gnome-zh-hans
        fonts-noto-cjk
    )
    local extra_packages=()

    if command -v check-language-support >/dev/null 2>&1; then
        read -r -a extra_packages <<< "$(check-language-support -l zh_CN 2>/dev/null || true)"
        if (( ${#extra_packages[@]} > 0 )); then
            packages+=("${extra_packages[@]}")
        fi
    fi

    refresh_package_lists || return 1
    "${SUDO[@]}" apt-get install -y "${packages[@]}" || return 1
    "${SUDO[@]}" update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh || return 1

    warn "中文语言包已安装，建议重新登录或重启后再检查界面语言是否已切换。"
}

repair_desktop() {
    ensure_ubuntu || return 1
    ensure_privilege_escalation || return 1

    warn "此操作会尝试修复 Kubuntu / KDE 相关桌面组件。"
    if ! confirm "确认继续修复桌面环境? [y/N]: "; then
        info "已取消修复。"
        return 0
    fi

    refresh_package_lists || return 1
    "${SUDO[@]}" dpkg --configure -a || return 1
    "${SUDO[@]}" apt-get -f install -y || return 1
    "${SUDO[@]}" apt-get install --reinstall -y kubuntu-desktop plasma-desktop dolphin sddm || return 1

    warn "桌面修复完成，建议手动重启系统。"
}

reinstall_ubuntu_20_04() {
    warn "“重装 Ubuntu 20.04” 不适合通过当前脚本直接执行。"
    warn "更安全的做法是：先备份数据，再使用 Ubuntu 20.04 安装介质重装系统。"
    warn "如果你愿意，我可以继续帮你单独整理一份重装前检查清单。"
}

ensure_release_upgrader() {
    ensure_privilege_escalation || return 1

    if command -v do-release-upgrade >/dev/null 2>&1; then
        return 0
    fi

    info "系统中未找到 do-release-upgrade，正在安装 Ubuntu 发行版升级工具..."
    refresh_package_lists || return 1
    "${SUDO[@]}" apt-get install -y ubuntu-release-upgrader-core || return 1
}

ensure_release_prompt_lts() {
    local release_upgrades_file="/etc/update-manager/release-upgrades"
    local tmp_file

    tmp_file="$(mktemp)" || return 1

    if [[ -f "$release_upgrades_file" ]]; then
        backup_file "$release_upgrades_file" || {
            rm -f "$tmp_file"
            return 1
        }

        if grep -q '^Prompt=' "$release_upgrades_file"; then
            sed 's/^Prompt=.*/Prompt=lts/' "$release_upgrades_file" > "$tmp_file"
        else
            cat "$release_upgrades_file" > "$tmp_file"
            printf '\nPrompt=lts\n' >> "$tmp_file"
        fi
    else
        printf '[DEFAULT]\nPrompt=lts\n' > "$tmp_file"
    fi

    "${SUDO[@]}" install -m 644 "$tmp_file" "$release_upgrades_file"
    rm -f "$tmp_file"
}

start_lts_release_upgrade() {
    local target_label="$1"

    ensure_ubuntu || return 1
    ensure_release_upgrader || return 1

    show_current_system || return 1
    warn "开始发行版升级前，请确认已经备份重要数据，并预留足够磁盘空间。"
    warn "如果系统启用了第三方软件源，建议先停用相关源，避免升级中断。"

    if ! confirm "确认开始升级到 ${target_label}? [y/N]: "; then
        info "已取消发行版升级。"
        return 0
    fi

    info "先更新当前系统软件包，确保升级前状态尽可能干净..."
    upgrade_current_release_packages || return 1

    if [[ -f /run/reboot-required ]]; then
        warn "当前系统提示需要重启。请先重启系统，然后再次运行本脚本继续升级。"
        return 1
    fi

    ensure_release_prompt_lts || return 1

    info "即将启动 do-release-upgrade。后续步骤可能持续较久，并会进入交互式升级过程。"
    "${SUDO[@]}" do-release-upgrade
}

upgrade_to_ubuntu_22_04() {
    ensure_ubuntu || return 1

    case "$CURRENT_VERSION" in
        20.04)
            start_lts_release_upgrade "Ubuntu 22.04 LTS"
            ;;
        22.04)
            info "当前系统已经是 Ubuntu 22.04 LTS。"
            ;;
        *)
            if dpkg --compare-versions "$CURRENT_VERSION" gt "$TARGET_22_04"; then
                info "当前系统版本 ${CURRENT_VERSION} 已高于 Ubuntu 22.04，无需执行该升级。"
            else
                warn "当前版本 ${CURRENT_VERSION} 不在此脚本定义的 22.04 升级路径中。"
            fi
            ;;
    esac
}

upgrade_to_ubuntu_24_04_lts() {
    ensure_ubuntu || return 1

    case "$CURRENT_VERSION" in
        20.04)
            warn "Ubuntu LTS 不能从 20.04 直接跳到 24.04.4。"
            warn "请先执行“升级到 Ubuntu 22.04”，成功后再运行本选项升级到 Ubuntu ${TARGET_24_04_POINT} LTS。"
            ;;
        22.04)
            start_lts_release_upgrade "Ubuntu ${TARGET_24_04_POINT} LTS"
            ;;
        24.04)
            info "当前系统已经位于 Ubuntu 24.04 LTS 轨道。"
            if confirm "是否执行一次完整更新，以同步到当前仓库可用的最新点版本（例如 ${TARGET_24_04_POINT}）? [y/N]: "; then
                upgrade_current_release_packages
            else
                info "已取消更新。"
            fi
            ;;
        *)
            if dpkg --compare-versions "$CURRENT_VERSION" gt "$TARGET_24_04"; then
                info "当前系统版本 ${CURRENT_VERSION} 已高于 Ubuntu 24.04，无需执行该升级。"
            else
                warn "当前版本 ${CURRENT_VERSION} 不在此脚本定义的 24.04 LTS 升级路径中。"
            fi
            ;;
    esac
}

change_to_163_mirrors() {
    ensure_ubuntu || return 1
    ensure_privilege_escalation || return 1

    info "准备将 Ubuntu 官方仓库切换到 163 镜像。"
    info "将根据当前系统代号自动生成源配置：${CURRENT_CODENAME}"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsI --max-time 10 "${MIRROR_URL}/dists/${CURRENT_CODENAME}/Release" >/dev/null; then
            warn "未能确认 163 镜像中存在 ${CURRENT_CODENAME} 发行版目录，建议先手动检查镜像可用性。"
        fi
    fi

    if ! confirm "确认切换到 163 镜像源? [y/N]: "; then
        info "已取消切换。"
        return 0
    fi

    backup_file /etc/apt/sources.list || return 1
    disable_file_with_backup /etc/apt/sources.list.d/ubuntu.sources || return 1

    local tmp_file
    tmp_file="$(mktemp)" || return 1

    cat > "$tmp_file" <<EOF
deb ${MIRROR_URL} ${CURRENT_CODENAME} main restricted universe multiverse
deb ${MIRROR_URL} ${CURRENT_CODENAME}-security main restricted universe multiverse
deb ${MIRROR_URL} ${CURRENT_CODENAME}-updates main restricted universe multiverse
deb ${MIRROR_URL} ${CURRENT_CODENAME}-backports main restricted universe multiverse
deb-src ${MIRROR_URL} ${CURRENT_CODENAME} main restricted universe multiverse
deb-src ${MIRROR_URL} ${CURRENT_CODENAME}-security main restricted universe multiverse
deb-src ${MIRROR_URL} ${CURRENT_CODENAME}-updates main restricted universe multiverse
deb-src ${MIRROR_URL} ${CURRENT_CODENAME}-backports main restricted universe multiverse
EOF

    "${SUDO[@]}" install -m 644 "$tmp_file" /etc/apt/sources.list
    rm -f "$tmp_file"

    refresh_package_lists || return 1
    info "163 镜像源切换完成。"
}

run_menu_action() {
    local action="$1"
    local exit_code=0

    "$action" || exit_code=$?
    if (( exit_code != 0 )); then
        warn "操作未成功完成，退出码：${exit_code}"
    fi

    pause
}

main_menu() {
    while true; do
        if command -v clear >/dev/null 2>&1; then
            clear
        fi
        echo "================ ${SCRIPT_NAME} ================"
        show_current_system || true
        echo
        echo "请选择一个操作："
        echo "1) 检测并安装 Kubuntu 桌面"
        echo "2) 安装中文语言包"
        echo "3) 修复 Kubuntu 桌面"
        echo "4) 重装 Ubuntu 20.04 说明"
        echo "5) 升级到 Ubuntu 22.04 LTS"
        echo "6) 升级到 Ubuntu 24.04.4 LTS"
        echo "7) 更换为 163 镜像源"
        echo "8) 退出"
        read -r -p "请输入你的选择 (1-8): " choice

        case "$choice" in
            1)
                run_menu_action check_kubuntu
                ;;
            2)
                run_menu_action install_chinese_language
                ;;
            3)
                run_menu_action repair_desktop
                ;;
            4)
                run_menu_action reinstall_ubuntu_20_04
                ;;
            5)
                run_menu_action upgrade_to_ubuntu_22_04
                ;;
            6)
                run_menu_action upgrade_to_ubuntu_24_04_lts
                ;;
            7)
                run_menu_action change_to_163_mirrors
                ;;
            8)
                echo "退出脚本。"
                exit 0
                ;;
            *)
                warn "无效选择，请输入 1-8。"
                pause
                ;;
        esac
    done
}

trap 'echo; warn "检测到中断，脚本已退出。"; exit 130' INT TERM

main_menu
