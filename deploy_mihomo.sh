#!/bin/bash
set -eu -o pipefail

# ==================================================================
# mihomo 自动化部署与配置更新脚本
# ==================================================================
CONFIG_DIR="/etc/mihomo"
MIHOMO_BIN_PATH="/usr/local/bin/mihomo"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/mihomo.service"

echo "🚀 开始执行 mihomo 部署/更新脚本..."

if ! command -v unzip &> /dev/null; then
  echo "🟡 unzip 未安装，正在尝试安装..."
  apt-get update && apt-get install -y unzip
  echo "✅ unzip 已安装。"
fi


if ! command -v mihomo &> /dev/null; then
  echo "🟡 mihomo 命令未找到，执行首次安装..."
  LATEST_RELEASE_INFO=$(curl -s "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")
  DOWNLOAD_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r '.assets[] | select(.name | test("linux-amd64-v")) | .browser_download_url')
  if [ -z "$DOWNLOAD_URL" ]; then echo "❌ 无法找到下载链接！"; exit 1; fi
  echo "正在下载最新版本..."
  wget -q -O mihomo.gz "$DOWNLOAD_URL"; gunzip -c mihomo.gz > mihomo; chmod +x mihomo; mv mihomo "$MIHOMO_BIN_PATH"
  echo "✅ mihomo 已成功安装到 $MIHOMO_BIN_PATH"
else
  echo "✅ mihomo 程序已存在，跳过安装步骤。"
fi


mkdir -p "$CONFIG_DIR"

# --- 生成最终配置文件 ---
echo "正在从模板生成最终配置文件..."
TEMP_CONFIG_FILE=$(mktemp)
cp "config.yaml" "$TEMP_CONFIG_FILE"

# 注入所有 Secrets
if [ -n "${MIHOMO_SUB_NB:-}" ]; then sed -i "s|__NB_SUB_URL__|${MIHOMO_SUB_NB}|g" "$TEMP_CONFIG_FILE"; fi
if [ -n "${MIHOMO_SUB_HNEKO:-}" ]; then sed -i "s|__HNEKO_SUB_URL__|${MIHOMO_SUB_HNEKO}|g" "$TEMP_CONFIG_FILE"; fi
if [ -n "${MIHOMO_CONTROLLER_SECRET:-}" ]; then sed -i "s|__CONTROLLER_SECRET__|${MIHOMO_CONTROLLER_SECRET}|g" "$TEMP_CONFIG_FILE"; fi

mv "$TEMP_CONFIG_FILE" "$CONFIG_DIR/config.yaml"
echo "✅ 最新配置文件已生成。"

# --- 配置并管理 systemd 服务 ---
if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
  echo "🟡 systemd 服务文件未找到，正在创建..."
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
  echo "✅ systemd 服务已创建。"
fi

echo "确保 mihomo 服务处于开机自启状态..."
systemctl enable mihomo

echo "正在重启 mihomo 服务以应用最新配置..."
systemctl restart mihomo

sleep 3
if systemctl is-active --quiet mihomo; then
  echo "🎉 mihomo 服务已成功启动并运行！"
else
  echo "❌ mihomo 服务启动失败！请使用 'journalctl -u mihomo -o cat -f' 命令检查日志。"
  exit 1
fi