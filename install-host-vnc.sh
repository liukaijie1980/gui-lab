#!/usr/bin/env bash
set -euo pipefail

# Install and configure x11vnc for host desktop sharing.
# Usage:
#   ./install-host-vnc.sh
# Optional env:
#   VNC_PORT=5900
#   VNC_PASSWORD=your_password

VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_USER="${SUDO_USER:-${USER}}"
VNC_HOME="$(getent passwd "${VNC_USER}" | cut -d: -f6)"
PASS_FILE="${VNC_HOME}/.vnc/passwd"
SERVICE_FILE="/etc/systemd/system/x11vnc.service"

if [[ -z "${VNC_HOME}" ]]; then
  echo "无法确定用户 ${VNC_USER} 的家目录。" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SHIFTKEY_REPO="/etc/apt/sources.list.d/packagecloud-shiftkey-desktop.list"
SHIFTKEY_REPO_DISABLED="${SHIFTKEY_REPO}.disabled-by-install-host-vnc"
RESTORE_SHIFTKEY_REPO=0

if [[ -f "${SHIFTKEY_REPO}" ]]; then
  echo "检测到失效第三方源，临时禁用: ${SHIFTKEY_REPO}"
  mv "${SHIFTKEY_REPO}" "${SHIFTKEY_REPO_DISABLED}"
  RESTORE_SHIFTKEY_REPO=1
fi

cleanup() {
  if [[ "${RESTORE_SHIFTKEY_REPO}" -eq 1 && -f "${SHIFTKEY_REPO_DISABLED}" ]]; then
    mv "${SHIFTKEY_REPO_DISABLED}" "${SHIFTKEY_REPO}"
    echo "已恢复第三方源文件: ${SHIFTKEY_REPO}"
  fi
}
trap cleanup EXIT

apt-get update
apt-get install -y x11vnc

mkdir -p "$(dirname "${PASS_FILE}")"
if [[ -n "${VNC_PASSWORD}" ]]; then
  x11vnc -storepasswd "${VNC_PASSWORD}" "${PASS_FILE}"
else
  echo "请输入宿主机 VNC 密码（不会回显）:"
  x11vnc -storepasswd "${PASS_FILE}"
fi

chown -R "${VNC_USER}:${VNC_USER}" "$(dirname "${PASS_FILE}")"
chmod 700 "$(dirname "${PASS_FILE}")"
chmod 600 "${PASS_FILE}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=x11vnc server for current X11 desktop
After=display-manager.service
Wants=display-manager.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
ExecStart=/usr/bin/x11vnc -find -auth guess -rfbport ${VNC_PORT} -forever -loop -noxdamage -repeat -shared -rfbauth ${PASS_FILE}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable --now x11vnc.service

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${VNC_PORT}/tcp" || true
fi

echo "x11vnc 已安装并启动。"
echo "VNC 地址: <宿主机IP>:${VNC_PORT}"
echo "服务状态: systemctl status x11vnc --no-pager"
