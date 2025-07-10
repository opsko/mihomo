#!/bin/bash
set -eu -o pipefail

# ==================================================================
# mihomo 自动化部署与配置更新脚本
# ==================================================================
CONFIG_DIR="/etc/mihomo"
MIHOMO_BIN_PATH="/usr/local/bin/mihomo"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/mihomo.service"


# 函数：打印带边框的标题
log_header() {
    echo ""
    echo "╔═════════════════════════════════════════════════════════════════╗"
    echo "║ $1"
    echo "╚═════════════════════════════════════════════════════════════════╝"
}

# 函数：检查并自动安装所有必需的命令
check_and_install_dependencies() {
    log_header "⚙️  Phase 1/4: Checking and Installing Dependencies"
    
    # 定义命令和其对应的安装包名
    declare -A deps=(
        [curl]="curl"
        [jq]="jq"
        [wget]="wget"
        [unzip]="unzip"
        [gunzip]="gzip"
    )
    
    local missing_pkgs=()
    for cmd in "${!deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "  🟡 Dependency command '$cmd' not found. Adding package '${deps[$cmd]}' to installation list."
            missing_pkgs+=("${deps[$cmd]}")
        else
            echo "  ✅ Dependency command '$cmd' is present."
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "  - Attempting to install missing packages: ${missing_pkgs[*]}..."
        # 使用 DEBIAN_FRONTEND=noninteractive 避免 apt-get 在安装时弹出交互式对话框
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_pkgs[@]}"
        
        # 再次检查，确保安装成功
        for cmd in "${!deps[@]}"; do
             if ! command -v "$cmd" &> /dev/null; then
                # 如果在需要安装的列表里，但安装后仍然找不到，则报错
                if [[ " ${missing_pkgs[*]} " =~ " ${deps[$cmd]} " ]]; then
                     echo "🔴 FATAL: Failed to install package '${deps[$cmd]}' for command '$cmd'. Please install it manually."
                     exit 1
                fi
             fi
        done
        echo "  ✅ All missing dependencies have been installed."
    else
        echo "  ✅ All dependencies are already satisfied."
    fi
}


# 函数：安装 mihomo 主程序
install_mihomo_binary() {
    log_header "🚀 Phase 2/4: Installing mihomo Binary"
    if ! command -v mihomo &> /dev/null; then
        echo "  - mihomo not found, proceeding with installation..."
        local LATEST_RELEASE_INFO=$(curl -s "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")
        local DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r '.assets[] | select(.name | test("linux-amd64-v")) | .browser_download_url')
        if [ -z "$DOWNLOAD_URL" ]; then echo "❌ Cannot find download URL!"; exit 1; fi

        echo "  - Downloading latest version..."
        wget -q -O mihomo.gz "$DOWNLOAD_URL"
        echo "  - Decompressing and installing..."
        gunzip -c mihomo.gz > mihomo
        chmod +x mihomo
        mv mihomo "$MIHOMO_BIN_PATH"
        rm mihomo.gz
        echo "  ✅ mihomo has been successfully installed to $MIHOMO_BIN_PATH"
    else
        echo "  ✅ mihomo is already installed. Skipping."
    fi
}


# 函数：生成最终配置文件
generate_config() {
    log_header "📝 Phase 3/4: Generating Final Configuration File"
    echo "  - Creating config from template and secrets..."
    mkdir -p "$CONFIG_DIR"
    local TEMP_CONFIG_FILE=$(mktemp)
    cp "config.yaml" "$TEMP_CONFIG_FILE"

    # 对包含特殊字符的 URL 进行转义，以安全地替换
    local SAFE_SUB_A=$(echo "${MIHOMO_SUB_A:-}" | sed 's/[&/\]/\\&/g')
    local SAFE_SUB_B=$(echo "${MIHOMO_SUB_B:-}" | sed 's/[&/\]/\\&/g')

    if [ -n "$SAFE_SUB_A" ]; then sed -i "s|__SUB_A_URL__|${SAFE_SUB_A}|g" "$TEMP_CONFIG_FILE"; fi
    if [ -n "$SAFE_SUB_B" ]; then sed -i "s|__SUB_B_URL__|${SAFE_SUB_B}|g" "$TEMP_CONFIG_FILE"; fi
    if [ -n "${MIHOMO_CONTROLLER_SECRET:-}" ]; then sed -i "s|__CONTROLLER_SECRET__|${MIHOMO_CONTROLLER_SECRET}|g" "$TEMP_CONFIG_FILE"; fi

    mv "$TEMP_CONFIG_FILE" "$CONFIG_DIR/config.yaml"
    echo "  ✅ Final config.yaml has been generated."
}


# 函数：设置并管理 systemd 服务
manage_systemd_service() {
    log_header "⚙️  Phase 4/4: Setting up and Restarting systemd Service"
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        echo "  - systemd service file not found. Creating..."
        bash -c "cat > $SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        echo "  ✅ systemd service file created."
    fi

    echo "  - Enabling and restarting mihomo service..."
    systemctl enable mihomo
    systemctl restart mihomo
    
    sleep 3
    if systemctl is-active --quiet mihomo; then
        log_header "🎉 Deployment Successful!"
        echo "     mihomo service is active and running."
    else
        log_header "❌ Deployment Failed!"
        echo "     mihomo service failed to start."
        echo "     Please run 'journalctl -u mihomo -o cat -f' on your server to check the logs."
        exit 1
    fi
}


# --- 主执行流程 ---
main() {
    check_and_install_dependencies
    install_mihomo_binary
    generate_config
    manage_systemd_service
}

# 执行主函数
main