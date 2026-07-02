#!/usr/bin/env bash
# 发现当前用户的 X 会话并启动宿主机 VNC。
# - x11vnc：剪贴板双向可用，但中文走 RFB Latin-1 会乱码
# - x0vncserver >= 1.15：支持剪贴板 + Extended Clipboard (UTF-8)
# Ubuntu 22.04 apt 自带 tigervnc 1.12 的 x0vncserver 无剪贴板，默认回退 x11vnc。
set -euo pipefail

VNC_USER="${1:?usage: host-vnc-start.sh USER PORT PASSWD_FILE}"
VNC_PORT="${2:?usage: host-vnc-start.sh USER PORT PASSWD_FILE}"
PASS_FILE="${3:?usage: host-vnc-start.sh USER PORT PASSWD_FILE}"
VNC_BACKEND="${VNC_BACKEND:-auto}"

HOME_DIR="$(getent passwd "${VNC_USER}" | cut -d: -f6)"
UID_NUM="$(id -u "${VNC_USER}")"

discover_display() {
  local line display="" xauth=""

  while IFS= read -r line; do
    display="$(grep -oE ':[0-9]+' <<<"${line}" | head -1 || true)"
    if [[ "${line}" == *"-auth"* ]]; then
      xauth="$(sed -n 's/.* -auth \([^ ]*\).*/\1/p' <<<"${line}" | head -1)"
    fi
    [[ -n "${display}" ]] && break
  done < <(ps -u "${VNC_USER}" -o args= 2>/dev/null | grep -E '/X(org)? ' || true)

  if [[ -z "${display}" ]] && command -v loginctl >/dev/null 2>&1; then
    local sid d
    while read -r sid _ _; do
      d="$(loginctl show-session "${sid}" -p Display --value 2>/dev/null || true)"
      if [[ -n "${d}" ]]; then
        display="${d}"
        break
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="${VNC_USER}" '$3==u')
  fi

  if [[ -z "${display}" ]]; then
    local sock n best=-1
    for sock in /tmp/.X11-unix/X*; do
      [[ -S "${sock}" ]] || continue
      [[ "$(stat -c '%U' "${sock}" 2>/dev/null || echo)" == "${VNC_USER}" ]] || continue
      n="${sock##*/X}"
      [[ "${n}" =~ ^[0-9]+$ ]] || continue
      if (( n < 100 && n > best )); then
        best="${n}"
        display=":${n}"
      fi
    done
  fi

  [[ -n "${display}" ]] || display=":0"

  if [[ -n "${xauth}" && "${xauth}" != /* ]]; then
    xauth="${HOME_DIR}/${xauth}"
  fi
  if [[ -z "${xauth}" || ! -f "${xauth}" ]]; then
    if [[ -f "${HOME_DIR}/.Xauthority" ]]; then
      xauth="${HOME_DIR}/.Xauthority"
    elif [[ -f "/run/user/${UID_NUM}/gdm/Xauthority" ]]; then
      xauth="/run/user/${UID_NUM}/gdm/Xauthority"
    elif [[ -f "/var/run/lightdm/root/:0" ]]; then
      xauth="/var/run/lightdm/root/:0"
    else
      xauth="${HOME_DIR}/.Xauthority"
    fi
  fi

  printf '%s\n%s\n' "${display}" "${xauth}"
}

wait_for_display() {
  local display="$1" xauth="$2" sock="" i
  sock="/tmp/.X11-unix/X${display#:}"

  for i in $(seq 1 60); do
    if [[ -S "${sock}" ]] && [[ -f "${xauth}" ]]; then
      if env HOME="${HOME_DIR}" DISPLAY="${display}" XAUTHORITY="${xauth}" \
        xdpyinfo >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

tigervnc_has_clipboard() {
  local bin="$1" ver major minor
  [[ -x "${bin}" ]] || return 1
  ver="$("${bin}" -version 2>&1 | head -1 || true)"
  [[ "${ver}" =~ ([0-9]+)\.([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major > 1 || (major == 1 && minor >= 15) ))
}

pick_x0vncserver() {
  local candidate
  for candidate in \
    /opt/tigervnc/usr/bin/x0vncserver \
    /opt/tigervnc/bin/x0vncserver \
    /usr/bin/x0vncserver; do
    if tigervnc_has_clipboard "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

mapfile -t _session < <(discover_display)
DISPLAY="${_session[0]}"
XAUTHORITY="${_session[1]}"
unset _session

if ! wait_for_display "${DISPLAY}" "${XAUTHORITY}"; then
  echo "host-vnc-start: 等待 X 会话就绪超时 (DISPLAY=${DISPLAY}, XAUTHORITY=${XAUTHORITY})" >&2
  exit 1
fi

export HOME="${HOME_DIR}" DISPLAY XAUTHORITY

_x0vnc=""
if [[ "${VNC_BACKEND}" == "tigervnc" || "${VNC_BACKEND}" == "auto" ]]; then
  _x0vnc="$(pick_x0vncserver || true)"
fi

if [[ -n "${_x0vnc}" && ( "${VNC_BACKEND}" == "tigervnc" || "${VNC_BACKEND}" == "auto" ) ]]; then
  echo "host-vnc-start: 使用 ${_x0vnc}（UTF-8 剪贴板） DISPLAY=${DISPLAY}" >&2
  _x0_args=(
    -display "${DISPLAY}"
    -rfbport "${VNC_PORT}"
    -PasswordFile "${PASS_FILE}"
    -SecurityTypes VncAuth
    -AlwaysShared=1
    -localhost=0
    -SendCutText=1
    -AcceptCutText=1
  )
  # Ubuntu apt 包装脚本仍用旧式 -fg；上游 1.16 二进制用 X0 参数风格
  if [[ "${_x0vnc}" == *"/opt/tigervnc/"* ]] || "${_x0vnc}" -version 2>&1 | grep -q 'TigerVNC server version 1.1[6-9]'; then
    exec "${_x0vnc}" "${_x0_args[@]}"
  fi
  exec "${_x0vnc}" -fg "${_x0_args[@]}"
fi

if [[ "${VNC_BACKEND}" == "tigervnc" ]]; then
  echo "host-vnc-start: 未找到带剪贴板的 x0vncserver (>=1.15)，请安装 /opt/tigervnc 或设 VNC_BACKEND=x11vnc" >&2
  exit 1
fi

if ! command -v x11vnc >/dev/null 2>&1; then
  echo "host-vnc-start: 未找到 x11vnc" >&2
  exit 1
fi

echo "host-vnc-start: 使用 x11vnc（剪贴板可用；中文可能乱码） DISPLAY=${DISPLAY}" >&2
exec x11vnc -display "${DISPLAY}" -auth "${XAUTHORITY}" \
  -rfbport "${VNC_PORT}" \
  -forever -loop -noxdamage -repeat -shared \
  -rfbauth "${PASS_FILE}"
