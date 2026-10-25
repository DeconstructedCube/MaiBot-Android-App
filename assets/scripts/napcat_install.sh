#!/bin/bash
set -e

MAGENTA='\033[0;1;35;95m'
RED='\033[0;1;31;91m'
YELLOW='\033[0;1;33;93m'
GREEN='\033[0;1;32;92m'
CYAN='\033[0;1;36;96m'
BLUE='\033[0;1;34;94m'
NC='\033[0m'

function log() {
    time=$(date +"%Y-%m-%d %H:%M:%S")
    message="[${time}]: $1 "
    case "$1" in
    *"失败"* | *"错误"* | *"当前用户不是root用户"* | *"无法连接"*)
        echo -e "${RED}${message}${NC}"
        ;;
    *"成功"*)
        echo -e "${GREEN}${message}${NC}"
        ;;
    *"忽略"* | *"跳过"* | *"默认"* | *"警告"*)
        echo -e "${YELLOW}${message}${NC}"
        ;;
    *)
        echo -e "${BLUE}${message}${NC}"
        ;;
    esac
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "错误: 此脚本需要以 root 权限运行。"
        exit 1
    fi
    log "脚本正在以 root 权限运行。"
}

function detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        package_manager="apt-get"
    elif command -v dnf &> /dev/null; then
        package_manager="dnf"
    elif command -v zypper &> /dev/null; then
        package_manager="zypper"
    else
        log "高级包管理器检查失败, 目前仅支持apt-get/dnf/zypper。"
        exit 1
    fi
    log "当前高级包管理器: ${package_manager}"
}

function detect_package_installer() {
    if command -v dpkg &> /dev/null; then
        package_installer="dpkg"
    elif command -v rpm &> /dev/null; then
        package_installer="rpm"
    else
        log "基础包管理器检查失败, 目前仅支持dpkg/rpm。"
        exit 1
    fi
    log "当前基础包管理器: ${package_installer}"
}

function install_dependency() {
    log "开始更新依赖..."
    detect_package_manager

    if [ "${package_manager}" = "apt-get" ]; then
        apt-get update -y -qq
        apt-get install -y -qq zip unzip jq curl xvfb screen xauth procps g++ libnss3 libgbm1 libgssapi-krb5-2
        if apt-cache show libasound2t64 >/dev/null 2>&1; then
            apt-get install -y -qq libasound2t64
        else
            apt-get install -y -qq libasound2
        fi
    elif [ "${package_manager}" = "dnf" ]; then
        dnf install -y epel-release || true
        dnf install --allowerasing -y zip unzip jq curl xorg-x11-server-Xvfb xorg-x11-xauth screen procps-ng gcc-c++ krb5-libs
    elif [ "${package_manager}" = "zypper" ]; then
        zypper --non-interactive install zip unzip jq curl xvfb-run xauth screen procps gcc-c++ krb5 cpio
    fi
    log "依赖安装成功..."
}

function curl_download() {
    local source="$1" destination="$2" partial status
    partial=$(mktemp "${destination}.XXXXXX") || return 1
    if curl -k -fL --connect-timeout "${NAPCAT_CONNECT_TIMEOUT:-15}" \
        --max-time "${NAPCAT_DOWNLOAD_TIMEOUT:-600}" \
        "$source" -o "$partial"; then
        mv -- "$partial" "$destination"
    else
        status=$?
        rm -f -- "$partial"
        return "$status"
    fi
}

function network_test() {
    if [ -n "${network_selected:-}" ]; then return 0; fi
    target_proxy=""
    local proxy probe_file
    local proxies=("https://ghfast.top" "https://gh-proxy.com" "https://mirror.ghproxy.com" "https://ghproxy.net" "")
    probe_file=$(mktemp)
    log "开始网络测试: Github..."
    for proxy in "${proxies[@]}"; do
        if curl -k -fLsS --connect-timeout 5 --max-time 10 \
            "${proxy:+${proxy}/}https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json" \
            -o "$probe_file" 2>/dev/null &&
            grep -q '"napcat"' "$probe_file" 2>/dev/null; then
            target_proxy="$proxy"
            network_selected=1
            rm -f -- "$probe_file"
            log "GitHub 下载线路: ${target_proxy:-直连}"
            return 0
        fi
    done
    rm -f -- "$probe_file"
    log "警告: 代理探测均未命中，尝试直连..."
    target_proxy=""
    network_selected=1
}

function create_tmp_folder() {
    mkdir -p ./napcat
}

function clean() {
    rm -rf ./NapCat.Shell.zip ./QQ.deb ./QQ.rpm
}

function download_napcat() {
    create_tmp_folder
    default_file="NapCat.Shell.zip"
    if [ -f "${default_file}" ]; then
        log "检测到已下载NapCat安装包,跳过下载..."
    else
        log "开始下载NapCat安装包,请稍等..."
        network_test
        napcat_download_url="${target_proxy:+${target_proxy}/}https://github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip"
        if ! curl_download "${napcat_download_url}" "${default_file}"; then
            log "文件下载失败, 请检查网络错误。"
            clean
            exit 1
        fi
        log "${default_file} 成功下载。"
    fi

    log "正在验证 ${default_file}..."
    if ! unzip -t "${default_file}" > /dev/null 2>&1; then
        log "文件验证失败, 请检查错误。"
        clean
        exit 1
    fi

    log "正在解压 ${default_file} (保留已有 config 与 plugins)..."
    unzip -q -o -d ./napcat NapCat.Shell.zip -x 'config/*' 'plugins/*' || true
    unzip -q -n -d ./napcat NapCat.Shell.zip || true
}

function get_system_arch() {
    system_arch=$(arch | sed s/aarch64/arm64/ | sed s/x86_64/amd64/)
    if [[ "${system_arch}" != "amd64" && "${system_arch}" != "arm64" ]]; then
        log "不支持的系统架构: ${system_arch}，仅支持 amd64/arm64。"
        exit 1
    fi
    log "当前系统架构: ${system_arch}"
}

function get_qq_download_url() {
    if [ -n "${QQ_DOWNLOAD_URL:-}" ]; then
        qq_download_url="${QQ_DOWNLOAD_URL}"
        log "使用环境变量指定的 LinuxQQ 下载地址: ${qq_download_url}"
        return 0
    fi

    log "正在获取与 NapCat 适配的最新官方 LinuxQQ 下载链接..."
    qq_download_url=""
    local qq_version=""

    # 1. 优先使用 NapCat 2026-10 验证通过的官方高版本 (3.2.34-53644)
    local fallback_file=""
    if [ "${system_arch}" = "amd64" ]; then
        if [ "${package_installer}" = "rpm" ]; then
            fallback_file="linuxqq_3.2.34-53644_x86_64.rpm"
        elif [ "${package_installer}" = "dpkg" ]; then
            fallback_file="linuxqq_3.2.34-53644_amd64.deb"
        fi
    elif [ "${system_arch}" = "arm64" ]; then
        if [ "${package_installer}" = "rpm" ]; then
            fallback_file="linuxqq_3.2.34-53644_aarch64.rpm"
        elif [ "${package_installer}" = "dpkg" ]; then
            fallback_file="linuxqq_3.2.34-53644_arm64.deb"
        fi
    fi
    local candidate_34="https://qqdl.gtimg.cn/qqfile/QQNT/9.9.36/beta/9ee04bef/${fallback_file}"
    if curl -k -s -I --connect-timeout 5 --max-time 8 "${candidate_34}" | grep -qE "^HTTP/.* (200|301|302)"; then
        qq_download_url="${candidate_34}"
        log "已命中 LinuxQQ 3.2.34-53644 官方镜像源"
        return 0
    fi

    # 2. 动态从腾讯官方配置（Rainbow CDN）获取最新可用版本
    local config_urls=(
        "https://qq-web.cdn-go.cn/im.qq.com_new/latest/rainbow/pcConfig.json"
        "https://im.qq.com/proxy/domain/qq-web.cdn-go.cn/im.qq.com_new/latest/rainbow/pcConfig.json"
    )

    for cfg_url in "${config_urls[@]}"; do
        local config_json
        config_json=$(curl -k -s -L --connect-timeout 5 --max-time 10 "${cfg_url}" 2>/dev/null || true)
        if [ -n "${config_json}" ] && command -v jq &> /dev/null; then
            qq_version=$(echo "${config_json}" | jq -r '.Linux.version // empty' 2>/dev/null || true)
            if [ "${system_arch}" = "amd64" ]; then
                if [ "${package_installer}" = "rpm" ]; then
                    qq_download_url=$(echo "${config_json}" | jq -r '.Linux.x64DownloadUrl.rpm // empty' 2>/dev/null || true)
                elif [ "${package_installer}" = "dpkg" ]; then
                    qq_download_url=$(echo "${config_json}" | jq -r '.Linux.x64DownloadUrl.deb // empty' 2>/dev/null || true)
                fi
            elif [ "${system_arch}" = "arm64" ]; then
                if [ "${package_installer}" = "rpm" ]; then
                    qq_download_url=$(echo "${config_json}" | jq -r '.Linux.armDownloadUrl.rpm // empty' 2>/dev/null || true)
                elif [ "${package_installer}" = "dpkg" ]; then
                    qq_download_url=$(echo "${config_json}" | jq -r '.Linux.armDownloadUrl.deb // empty' 2>/dev/null || true)
                fi
            fi

            if [ -n "${qq_download_url}" ] && [ "${qq_download_url}" != "null" ]; then
                log "成功从腾讯 Rainbow CDN 获取 LinuxQQ (v${qq_version}) 下载地址"
                return 0
            fi
        fi
    done

    # 3. 最终兜底链接
    qq_download_url="${candidate_34}"
}

function install_linuxqq() {
    get_system_arch
    detect_package_installer
    qq_install_dir="/opt/QQ"
    qq_executable="$qq_install_dir/qq"

    if [ -f "$qq_install_dir/resources/app/package.json" ] && command -v jq &>/dev/null; then
        if jq -e '.buildVersion | tonumber >= 53644' "$qq_install_dir/resources/app/package.json" >/dev/null 2>&1; then
            log "已安装的 LinuxQQ 版本满足要求 (>= 53644)，跳过重复安装。"
            return 0
        fi
    fi

    get_qq_download_url
    log "准备安装 LinuxQQ: ${qq_download_url}"

    if [ "${package_manager}" = "dnf" ]; then
        if ! [ -f "QQ.rpm" ]; then
            curl_download "${qq_download_url}" "QQ.rpm"
        fi
        dnf localinstall -y ./QQ.rpm
        rm -f QQ.rpm
    elif [ "${package_manager}" = "apt-get" ]; then
        if ! [ -f "QQ.deb" ]; then
            curl_download "${qq_download_url}" "QQ.deb"
        fi
        apt-get install -f -y --allow-downgrades -qq ./QQ.deb
        apt-get install -y --allow-downgrades -qq libnss3 libgbm1 libgssapi-krb5-2
        if apt-cache show libasound2t64 >/dev/null 2>&1; then
            apt-get install -y -qq libasound2t64
        else
            apt-get install -y -qq libasound2
        fi
        rm -f QQ.deb
    fi
    log "LinuxQQ安装完成"
}

function download_launcher_so() {
    get_system_arch
    network_test

    cpp_url="https://raw.githubusercontent.com/NapNeko/napcat-linux-launcher/refs/heads/main/launcher.cpp"
    cpp_file="launcher.cpp"
    so_file="libnapcat_launcher.so"

    download_url="${target_proxy:+${target_proxy}/}${cpp_url}"

    log "开始下载 ${cpp_file} ..."
    if ! curl_download "${download_url}" "${cpp_file}"; then
        log "${cpp_file} 下载失败，请检查网络。"
        exit 1
    fi
    log "${cpp_file} 下载成功，正在编译 ${so_file} ..."
    g++ -shared -fPIC "${cpp_file}" -o "${so_file}.new" -ldl
    mv -- "${so_file}.new" "${so_file}"
    log "${so_file} 编译成功。"
}

if [ -t 1 ]; then clear 2>/dev/null || true; fi
log "NapCat Shell 自动化安装脚本"
check_root
install_dependency
download_napcat
install_linuxqq
download_launcher_so
clean

cat << 'EOF' > launcher.sh
#!/bin/bash
cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
trap "" SIGPIPE
if command -v xvfb-run >/dev/null 2>&1; then
    exec xvfb-run -a env LD_PRELOAD=./libnapcat_launcher.so /opt/QQ/qq --no-sandbox "$@"
else
    Xvfb :1 -screen 0 1x1x8 +extension GLX +render > /dev/null 2>&1 &
    export DISPLAY=:1
    exec env LD_PRELOAD=./libnapcat_launcher.so /opt/QQ/qq --no-sandbox "$@"
fi
EOF

chmod +x launcher.sh
log "NapCat 与 LinuxQQ 部署全部完成！"
