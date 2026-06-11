#!/usr/bin/env bash
# Kasm custom_startup：容器每次启动时自启 sshd，并在 KasmVNC 就绪后按 VNC_PW 同步 Web/SSH 密码。
# 由 run-ubuntu22-gui.sh 挂载到 /dockerstartup/custom_startup.sh（无需重建镜像）。
set -euo pipefail

_start_sshd() {
  if ! command -v sshd >/dev/null 2>&1; then
    return 0
  fi
  sudo mkdir -p /var/run/sshd
  sudo chmod 0755 /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    sudo /usr/sbin/sshd
  fi
}

_ensure_kasmvnc_blacklist_off() {
  local f=/home/kasm-user/.vnc/kasmvnc.yaml
  mkdir -p /home/kasm-user/.vnc
  if grep -qE 'blacklist_threshold:[[:space:]]*0' "$f" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$f" ]] && grep -q 'blacklist_threshold:' "$f"; then
    sed -i 's/blacklist_threshold:.*/    blacklist_threshold: 0/' "$f"
  else
    cat >>"$f" <<'EOF'
security:
  brute_force_protection:
    blacklist_threshold: 0
EOF
  fi
  chmod 600 "$f" 2>/dev/null || true
}

_sync_passwords_when_ready() {
  local pw="${VNC_PW:-}"
  [[ -z "${pw}" ]] && return 0

  local marker="/home/kasm-user/.cache/gui-bootstrap-pw-synced"
  local hash
  hash=$(printf '%s' "$pw" | md5sum | awk '{print $1}')
  if [[ -f "${marker}" ]] && [[ "$(cat "${marker}")" == "${hash}" ]]; then
    return 0
  fi

  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if ss -tln 2>/dev/null | grep -q ':6901 '; then
      break
    fi
    sleep 2
  done
  if ! ss -tln 2>/dev/null | grep -q ':6901 '; then
    return 0
  fi

  if command -v kasmvncpasswd >/dev/null 2>&1; then
    printf '%s\n%s\n' "$pw" "$pw" | kasmvncpasswd -u kasm_user -wro /home/kasm-user/.kasmpasswd
    printf '%s\n%s\n' "$pw" "$pw" | kasmvncpasswd -u kasm-user -wr /home/kasm-user/.kasmpasswd
    chmod 600 /home/kasm-user/.kasmpasswd
  fi
  echo "kasm-user:${pw}" | sudo chpasswd
  mkdir -p /home/kasm-user/.cache
  echo "${hash}" > "${marker}"
}

_start_sshd
_ensure_kasmvnc_blacklist_off
( _sync_passwords_when_ready ) &
exec sleep infinity
