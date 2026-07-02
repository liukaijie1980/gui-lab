#!/usr/bin/env bash
set -euo pipefail

# 为宿主机桌面提供浏览器访问（noVNC + websockify），剪贴板 UTF-8 需 TigerVNC >= 1.15 后端。
#
# Usage:
#   ./install-host-web-vnc.sh
# Optional env:
#   WEB_PORT=6080          Web 入口端口（默认 6080）
#   VNC_PORT=5900          本地 VNC 端口（host-vnc.service 监听）
#   NOVNC_VERSION=1.5.0    noVNC 版本（apt 包过旧，默认从 GitHub 安装到 /opt/novnc）
#   INSTALL_HOST_VNC=1     若 host-vnc 未装则先跑 install-host-vnc.sh（默认 1）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WEB_PORT="${WEB_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_VERSION="${NOVNC_VERSION:-1.5.0}"
INSTALL_HOST_VNC="${INSTALL_HOST_VNC:-1}"
NOVNC_PREFIX="/opt/novnc"
NOVNC_URL="https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz"
SERVICE_FILE="/etc/systemd/system/host-web-vnc.service"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

if [[ "${INSTALL_HOST_VNC}" == "1" ]] && ! systemctl is-enabled host-vnc.service >/dev/null 2>&1; then
  echo "先安装 host-vnc ..."
  bash "${SCRIPT_DIR}/install-host-vnc.sh"
fi

apt-get update
apt-get install -y websockify curl ca-certificates tar

install_novnc() {
  local tmp="/tmp/novnc-${NOVNC_VERSION}.tar.gz"
  echo "安装 noVNC ${NOVNC_VERSION} 到 ${NOVNC_PREFIX} ..."
  curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 3 \
    -o "${tmp}" "${NOVNC_URL}"
  rm -rf "${NOVNC_PREFIX}.new"
  mkdir -p "${NOVNC_PREFIX}.new"
  tar -xzf "${tmp}" -C "${NOVNC_PREFIX}.new" --strip-components=1
  if [[ ! -f "${NOVNC_PREFIX}.new/vnc.html" ]]; then
    echo "错误: 解压后未找到 vnc.html" >&2
    exit 1
  fi
  rm -rf "${NOVNC_PREFIX}"
  mv "${NOVNC_PREFIX}.new" "${NOVNC_PREFIX}"
}

install_novnc

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=noVNC web proxy for host desktop (UTF-8 clipboard with TigerVNC backend)
After=network-online.target host-vnc.service
Requires=host-vnc.service

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web=${NOVNC_PREFIX} ${WEB_PORT} 127.0.0.1:${VNC_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now host-web-vnc.service

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${WEB_PORT}/tcp" || true
fi

_backend="x11vnc"
if [[ -x /opt/tigervnc/usr/bin/x0vncserver || -x /opt/tigervnc/bin/x0vncserver ]]; then
  _backend="TigerVNC ${TIGERVNC_VERSION:-1.16}（UTF-8 剪贴板）"
fi

echo ""
echo "宿主机 Web 桌面已启用。"
echo "浏览器访问: http://<宿主机IP>:${WEB_PORT}/vnc.html"
echo "连接后在侧边栏输入 VNC 密码（与 ~/.vnc/passwd 相同），勾选自动重连可选。"
echo "VNC 后端: ${_backend}"
if [[ "${_backend}" == "x11vnc" ]]; then
  echo ""
  echo "提示: 当前后端为 x11vnc，Web 里粘贴中文仍可能乱码。"
  echo "请执行: INSTALL_TIGERVNC_UTF8=1 ./install-host-vnc.sh && systemctl restart host-vnc host-web-vnc"
fi
echo "服务状态: systemctl status host-web-vnc --no-pager"
