#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "用法: $0 <container_name>" >&2
  exit 1
fi

CONTAINER_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/manifest.env"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "未找到 manifest: ${MANIFEST}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${MANIFEST}"

FORCE_REFRESH_DOWNLOADS="${FORCE_REFRESH_DOWNLOADS:-0}"

# 容器内 localhost 不是宿主机；持久化 HOME 里的 .bashrc 若写死 127.0.0.1:10811 会导致 apt/wget 全失败。
# 这里在宿主机侧统一映射为 host.docker.internal，并用 --noprofile/--norc 避免 login shell 覆盖环境。
load_host_proxy() {
  if [[ -f "${HOME}/proxy.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/proxy.sh"
  elif [[ -f "/home/lkj/proxy.sh" ]]; then
    # shellcheck source=/dev/null
    source "/home/lkj/proxy.sh"
  elif [[ -f "${PARENT}/.env.ubuntu22-gui" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${PARENT}/.env.ubuntu22-gui"
    set +a
  fi
}

map_for_container() {
  local x="$1"
  if [[ -z "${x}" ]]; then
    printf ''
    return
  fi
  x="${x//localhost/host.docker.internal}"
  x="${x//127.0.0.1/host.docker.internal}"
  printf '%s' "$x"
}

load_host_proxy
RAW_HTTP="${http_proxy:-${HTTP_PROXY:-${proxy:-${PROXY:-}}}}"
RAW_HTTPS="${https_proxy:-${HTTPS_PROXY:-${RAW_HTTP}}}"
HTTP_PROXY_MAPPED="$(map_for_container "${RAW_HTTP}")"
HTTPS_PROXY_MAPPED="$(map_for_container "${RAW_HTTPS}")"
ALL_PROXY_MAPPED="$(map_for_container "${all_proxy:-${ALL_PROXY:-}}")"
_raw_no_sync="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}"
if [[ -z "${_raw_no_sync}" ]]; then
  NO_PROXY_VAL="localhost,127.0.0.1,::1,host.docker.internal"
elif [[ "${_raw_no_sync}" != *"host.docker.internal"* ]]; then
  NO_PROXY_VAL="${_raw_no_sync},host.docker.internal"
else
  NO_PROXY_VAL="${_raw_no_sync}"
fi
unset _raw_no_sync

apt_proxy_cli() {
  if [[ -n "${HTTP_PROXY_MAPPED}" ]]; then
    printf '%s' "-o Acquire::http::Proxy=${HTTP_PROXY_MAPPED} -o Acquire::https::Proxy=${HTTPS_PROXY_MAPPED:-${HTTP_PROXY_MAPPED}}"
  else
    printf '%s' "-o Acquire::http::Proxy=false -o Acquire::https::Proxy=false"
  fi
}
APTG="$(apt_proxy_cli)"

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "容器不存在: ${CONTAINER_NAME}" >&2
  exit 1
fi

wait_container_exec_ready() {
  local name="$1"
  local wait_secs="${SYNC_WAIT_SECS:-180}"
  local start_ts now_ts
  start_ts="$(date +%s)"
  echo "等待容器可 exec（最多 ${wait_secs}s）: ${name}" >&2
  while true; do
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= wait_secs )); then
      break
    fi
    local st
    st="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"
    if [[ "${st}" == "running" ]] && docker exec "${name}" true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "超时: 容器仍无法 exec。常见原因: HOME 挂载目录属主不是 1000:1000（见 README 故障排除）。请执行: docker logs ${name}" >&2
  return 1
}

wait_container_exec_ready "${CONTAINER_NAME}"

run_root() {
  docker exec -u 0 \
    -e "HOME=/root" \
    -e "HTTP_PROXY=${HTTP_PROXY_MAPPED}" \
    -e "HTTPS_PROXY=${HTTPS_PROXY_MAPPED}" \
    -e "http_proxy=${HTTP_PROXY_MAPPED}" \
    -e "https_proxy=${HTTPS_PROXY_MAPPED}" \
    -e "ALL_PROXY=${ALL_PROXY_MAPPED}" \
    -e "all_proxy=${ALL_PROXY_MAPPED}" \
    -e "NO_PROXY=${NO_PROXY_VAL}" \
    -e "no_proxy=${NO_PROXY_VAL}" \
    "${CONTAINER_NAME}" bash --noprofile --norc -c "$1"
}

echo "[1/5] 准备共享目录与基础工具"
run_root "mkdir -p /shared_apps/downloads /shared_apps/state /shared_apps/node-global /shared_apps/cursor"
run_root "apt-get ${APTG} update && DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y ca-certificates curl wget gnupg python3"

echo "[2/5] 安装/更新 Google Chrome"
if [[ "${FORCE_REFRESH_DOWNLOADS}" == "1" ]]; then
  echo "FORCE_REFRESH_DOWNLOADS=1，强制重下 Chrome 安装包"
  run_root "wget -O /shared_apps/downloads/google-chrome.deb '${CHROME_DEB_URL}'"
else
  run_root "if [[ -s /shared_apps/downloads/google-chrome.deb ]]; then echo '复用共享缓存: /shared_apps/downloads/google-chrome.deb'; else wget -O /shared_apps/downloads/google-chrome.deb '${CHROME_DEB_URL}'; fi"
fi
run_root "DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y /shared_apps/downloads/google-chrome.deb"

echo "[3/5] 安装/更新 GitHub Desktop"
# 勿用 curl|gpg 管道直接 -o 目标文件：若 keyring 已存在，gpg 会报「File exists」且 stdin 未消费完导致 curl(23)；
# 目标文件若已是二进制 keyring，再次 dearmor 会报「no valid OpenPGP data」。先下载 .asc 再 rm 后写出。
run_root "install -d -m 0755 /etc/apt/keyrings && rm -f /tmp/shiftkey-apt.asc /etc/apt/keyrings/shiftkey-packages.gpg && curl -fsSL '${GITHUB_DESKTOP_GPG_URL}' -o /tmp/shiftkey-apt.asc && gpg --batch --no-tty --dearmor --output /etc/apt/keyrings/shiftkey-packages.gpg /tmp/shiftkey-apt.asc && rm -f /tmp/shiftkey-apt.asc"
run_root "chmod a+r /etc/apt/keyrings/shiftkey-packages.gpg"
run_root "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/shiftkey-packages.gpg] ${GITHUB_DESKTOP_APT_DEB} any main' > /etc/apt/sources.list.d/shiftkey-packages.list"
run_root "apt-get ${APTG} update && DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y github-desktop"

echo "[4/5] 安装/更新 Cursor (共享 AppImage)"
if [[ "${FORCE_REFRESH_DOWNLOADS}" == "1" ]]; then
  echo "FORCE_REFRESH_DOWNLOADS=1，强制重下 Cursor AppImage"
  run_root "set -e; \
    tmp='/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}.part'; \
    rm -f \"\${tmp}\"; \
    cursor_url='${CURSOR_APPIMAGE_URL}'; \
    if [[ \"\${cursor_url}\" == *'/api/download?'* ]]; then \
      cursor_url=\"\$(curl -fsSL \"\${cursor_url}\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"downloadUrl\"])')\"; \
    fi; \
    if ! curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 \"\${cursor_url}\" -o \"\${tmp}\"; then \
      echo '主下载地址失败，尝试 Cursor API 获取直链重试...' >&2; \
      cursor_url=\"\$(curl -fsSL 'https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"downloadUrl\"])')\"; \
      curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 \"\${cursor_url}\" -o \"\${tmp}\"; \
    fi; \
    mv -f \"\${tmp}\" '/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}'"
else
  run_root "set -e; \
    if [[ -s '/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}' ]]; then \
      echo '复用共享缓存: /shared_apps/cursor/${CURSOR_APPIMAGE_NAME}'; \
    else \
      tmp='/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}.part'; \
      rm -f \"\${tmp}\"; \
      cursor_url='${CURSOR_APPIMAGE_URL}'; \
      if [[ \"\${cursor_url}\" == *'/api/download?'* ]]; then \
        cursor_url=\"\$(curl -fsSL \"\${cursor_url}\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"downloadUrl\"])')\"; \
      fi; \
      if ! curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 \"\${cursor_url}\" -o \"\${tmp}\"; then \
        echo '主下载地址失败，尝试 Cursor API 获取直链重试...' >&2; \
        cursor_url=\"\$(curl -fsSL 'https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"downloadUrl\"])')\"; \
        curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 \"\${cursor_url}\" -o \"\${tmp}\"; \
      fi; \
      mv -f \"\${tmp}\" '/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}'; \
    fi"
fi
run_root "chmod +x '/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}'"
run_root "cat > /usr/local/bin/cursor <<'EOF'
#!/usr/bin/env bash
exec '/shared_apps/cursor/${CURSOR_APPIMAGE_NAME}' --appimage-extract-and-run \"\$@\"
EOF
chmod +x /usr/local/bin/cursor
ln -sf /shared_apps/node-global/bin/claude /usr/local/bin/claude 2>/dev/null || true"

echo "[5/5] 安装/更新 Claude Code (共享 npm 前缀)"
run_root "if ! command -v node >/dev/null 2>&1 || [ \"\$(node -p 'process.versions.node.split(\".\")[0]')\" -lt 18 ]; then \
  echo '检测到 Node < 18，正在升级到 Node 20...'; \
  apt-get ${APTG} update && DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y ca-certificates curl gnupg; \
  install -d -m 0755 /etc/apt/keyrings; \
  rm -f /etc/apt/keyrings/nodesource.gpg /etc/apt/sources.list.d/nodesource.list; \
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --no-tty --dearmor --output /etc/apt/keyrings/nodesource.gpg; \
  chmod a+r /etc/apt/keyrings/nodesource.gpg; \
  echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main' > /etc/apt/sources.list.d/nodesource.list; \
  DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y --fix-broken || true; \
  DEBIAN_FRONTEND=noninteractive apt-get ${APTG} remove -y libnode-dev nodejs-doc npm || true; \
  dpkg --configure -a || true; \
  apt-get ${APTG} update && DEBIAN_FRONTEND=noninteractive apt-get ${APTG} install -y nodejs; \
fi"
run_root "npm config set prefix /shared_apps/node-global"
if [[ "${FORCE_REFRESH_DOWNLOADS}" == "1" ]]; then
  run_root "npm install -g '${CLAUDE_CODE_NPM_PKG}@${CLAUDE_CODE_NPM_VER}'"
else
  run_root "if [[ -x /shared_apps/node-global/bin/claude ]]; then echo '复用共享安装: /shared_apps/node-global/bin/claude'; else npm install -g '${CLAUDE_CODE_NPM_PKG}@${CLAUDE_CODE_NPM_VER}'; fi"
fi
run_root "ln -sf /shared_apps/node-global/bin/claude /usr/local/bin/claude"

echo "基础应用同步完成: ${CONTAINER_NAME}"
