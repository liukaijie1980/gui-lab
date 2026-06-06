#!/usr/bin/env bash
# 同步 Kasm Web 登录密码：kasm_user（官方）+ kasm-user（与 SSH 同名，避免用户填错用户名）
set -euo pipefail

CNAME="${1:?用法: $0 <容器名> <密码>}"
PW="${2:?用法: $0 <容器名> <密码>}"
WAIT_SECS="${SYNC_KASM_WAIT_SECS:-120}"

if ! docker inspect "${CNAME}" >/dev/null 2>&1; then
  echo "容器不存在: ${CNAME}" >&2
  exit 1
fi

deadline=$((SECONDS + WAIT_SECS))
ready=0
while (( SECONDS < deadline )); do
  if docker inspect -f '{{.State.Running}}' "${CNAME}" 2>/dev/null | grep -q true; then
    if docker exec "${CNAME}" grep -q "KasmVNC environment started" /dockerstartup/vnc_startup.log 2>/dev/null \
      || docker exec "${CNAME}" bash -lc 'ss -tln 2>/dev/null | grep -q ":6901 "' 2>/dev/null; then
      ready=1
      break
    fi
  fi
  sleep 2
done

if [[ "${ready}" != "1" ]]; then
  echo "等待 KasmVNC 就绪超时（${WAIT_SECS}s）: ${CNAME}" >&2
  exit 1
fi

docker exec -e "VNC_PASS=${PW}" "${CNAME}" bash -lc '
  set -euo pipefail
  f=/home/kasm-user/.kasmpasswd
  # -w 才允许鼠标/键盘；-r 仅只读（能看桌面但点不动）。两用户名都需 -w，避免 Web 填 kasm-user 时无法操作。
  printf "%s\n%s\n" "$VNC_PASS" "$VNC_PASS" | kasmvncpasswd -u kasm_user -wro "$f"
  printf "%s\n%s\n" "$VNC_PASS" "$VNC_PASS" | kasmvncpasswd -u kasm-user -wr "$f"
  chmod 600 "$f"
'

echo "已同步 Kasm Web 密码（kasm_user / kasm-user）: ${CNAME}"
