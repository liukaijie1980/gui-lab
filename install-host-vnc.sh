#!/usr/bin/env bash
set -euo pipefail

# Install host desktop VNC sharing.
#
# Backend selection (via host-vnc-start.sh):
#   - x11vnc (default on Ubuntu 22.04): clipboard works, Chinese may garble on Latin-1 RFB
#   - x0vncserver >= 1.15 (/opt/tigervnc): clipboard + UTF-8 Extended Clipboard
#
# Usage:
#   ./install-host-vnc.sh
# Optional env:
#   VNC_PORT=5900
#   VNC_PASSWORD=your_password
#   VNC_BACKEND=auto|x11vnc|tigervnc   (default: auto)
#   INSTALL_TIGERVNC_UTF8=1            (default: 1, try install upstream TigerVNC to /opt/tigervnc)
#   TIGERVNC_VERSION=1.16.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_SRC="${SCRIPT_DIR}/scripts/host-vnc-start.sh"
STARTUP_DST="/usr/local/bin/host-vnc-start.sh"

VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
VNC_BACKEND="${VNC_BACKEND:-auto}"
INSTALL_TIGERVNC_UTF8="${INSTALL_TIGERVNC_UTF8:-1}"
TIGERVNC_VERSION="${TIGERVNC_VERSION:-1.16.0}"
VNC_USER="${SUDO_USER:-${USER}}"
VNC_HOME="$(getent passwd "${VNC_USER}" | cut -d: -f6)"
PASS_FILE="${VNC_HOME}/.vnc/passwd"
SERVICE_FILE="/etc/systemd/system/host-vnc.service"
LEGACY_SERVICE="/etc/systemd/system/x11vnc.service"
TIGERVNC_PREFIX="/opt/tigervnc"
TIGERVNC_URL="https://downloads.sourceforge.net/project/tigervnc/stable/${TIGERVNC_VERSION}/tigervnc-${TIGERVNC_VERSION}.x86_64.tar.gz"

if [[ -z "${VNC_HOME}" ]]; then
  echo "无法确定用户 ${VNC_USER} 的家目录。" >&2
  exit 1
fi

if [[ ! -f "${STARTUP_SRC}" ]]; then
  echo "缺少启动脚本: ${STARTUP_SRC}" >&2
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
apt-get install -y x11vnc x11-utils curl ca-certificates

install_tigervnc_upstream() {
  local tmp="/tmp/tigervnc-${TIGERVNC_VERSION}.x86_64.tar.gz" root=""
  echo "尝试安装上游 TigerVNC ${TIGERVNC_VERSION} 到 ${TIGERVNC_PREFIX}（UTF-8 剪贴板）..."
  if ! curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 5 -C - \
    -o "${tmp}" "${TIGERVNC_URL}"; then
    echo "警告: 下载 TigerVNC ${TIGERVNC_VERSION} 失败，将使用 x11vnc 作为剪贴板后端。" >&2
    return 1
  fi
  rm -rf "${TIGERVNC_PREFIX}.new"
  mkdir -p "${TIGERVNC_PREFIX}.new"
  tar -xzf "${tmp}" -C "${TIGERVNC_PREFIX}.new" --strip-components=1
  if [[ ! -x "${TIGERVNC_PREFIX}.new/usr/bin/x0vncserver" ]]; then
    echo "警告: 解压后未找到 usr/bin/x0vncserver，跳过上游 TigerVNC。" >&2
    rm -rf "${TIGERVNC_PREFIX}.new"
    return 1
  fi
  rm -rf "${TIGERVNC_PREFIX}"
  mv "${TIGERVNC_PREFIX}.new" "${TIGERVNC_PREFIX}"
  echo "已安装上游 TigerVNC 到 ${TIGERVNC_PREFIX}"
}

if [[ "${INSTALL_TIGERVNC_UTF8}" == "1" && "${VNC_BACKEND}" != "x11vnc" ]]; then
  install_tigervnc_upstream || true
fi

install -m 0755 "${STARTUP_SRC}" "${STARTUP_DST}"

mkdir -p "$(dirname "${PASS_FILE}")"
if [[ -f "${PASS_FILE}" && -z "${VNC_PASSWORD}" ]]; then
  echo "保留已有 VNC 密码文件: ${PASS_FILE}"
elif [[ -n "${VNC_PASSWORD}" ]]; then
  if [[ -x "${TIGERVNC_PREFIX}/bin/vncpasswd" ]]; then
    printf '%s' "${VNC_PASSWORD}" | "${TIGERVNC_PREFIX}/bin/vncpasswd" -f > "${PASS_FILE}"
  elif [[ -x "${TIGERVNC_PREFIX}/usr/bin/vncpasswd" ]]; then
    printf '%s' "${VNC_PASSWORD}" | "${TIGERVNC_PREFIX}/usr/bin/vncpasswd" -f > "${PASS_FILE}"
  elif command -v vncpasswd >/dev/null 2>&1; then
    printf '%s' "${VNC_PASSWORD}" | vncpasswd -f > "${PASS_FILE}"
  else
    x11vnc -storepasswd "${VNC_PASSWORD}" "${PASS_FILE}"
  fi
else
  echo "请输入宿主机 VNC 密码（不会回显）:"
  if command -v vncpasswd >/dev/null 2>&1; then
    vncpasswd "${PASS_FILE}"
  else
    x11vnc -storepasswd "${PASS_FILE}"
  fi
fi

chown -R "${VNC_USER}:${VNC_USER}" "$(dirname "${PASS_FILE}")"
chmod 700 "$(dirname "${PASS_FILE}")"
chmod 600 "${PASS_FILE}"

if [[ -f "${LEGACY_SERVICE}" ]] || systemctl is-active x11vnc.service >/dev/null 2>&1; then
  echo "停止并禁用旧版 x11vnc.service ..."
  systemctl disable --now x11vnc.service 2>/dev/null || true
  rm -f "${LEGACY_SERVICE}"
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Host VNC server (x11vnc or TigerVNC x0vncserver)
After=display-manager.service network-online.target
Wants=display-manager.service

[Service]
Type=simple
User=${VNC_USER}
Group=${VNC_USER}
Environment=HOME=${VNC_HOME}
Environment=VNC_BACKEND=${VNC_BACKEND}
ExecStart=${STARTUP_DST} ${VNC_USER} ${VNC_PORT} ${PASS_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable --now host-vnc.service

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${VNC_PORT}/tcp" || true
fi

echo ""
echo "宿主机 VNC 已安装并启动。"
echo "VNC 地址: <宿主机IP>:${VNC_PORT}"
echo "服务状态: systemctl status host-vnc --no-pager"
if [[ -x "${TIGERVNC_PREFIX}/bin/x0vncserver" || -x "${TIGERVNC_PREFIX}/usr/bin/x0vncserver" ]]; then
  echo "当前后端: TigerVNC ${TIGERVNC_VERSION}（UTF-8 剪贴板）；客户端请用 TigerVNC Viewer 1.12+"
else
  echo "当前后端: x11vnc（剪贴板可用；中文粘贴可能乱码）"
  echo "如需 UTF-8：网络恢复后重跑 INSTALL_TIGERVNC_UTF8=1 ./install-host-vnc.sh"
fi
