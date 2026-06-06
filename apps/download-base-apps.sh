#!/usr/bin/env bash
# 仅将基础应用安装包下载到宿主机 ./shared_apps（与 compose 挂载一致），不在容器内执行 apt/npm 安装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/manifest.env"
DOWNLOADS_DIR="${PARENT}/shared_apps/downloads"
CURSOR_DIR="${PARENT}/shared_apps/cursor"
STATE_DIR="${PARENT}/shared_apps/state"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "未找到 manifest: ${MANIFEST}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${MANIFEST}"

FORCE_REFRESH_DOWNLOADS="${FORCE_REFRESH_DOWNLOADS:-0}"

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

load_host_proxy

export_http_proxy_for_curl() {
  local h="${http_proxy:-${HTTP_PROXY:-${proxy:-${PROXY:-}}}}"
  local hs="${https_proxy:-${HTTPS_PROXY:-${h}}}"
  export http_proxy="${h:-}"
  export https_proxy="${hs:-}"
  export HTTP_PROXY="${h:-}"
  export HTTPS_PROXY="${hs:-}"
  export ALL_PROXY="${all_proxy:-${ALL_PROXY:-}}"
  export NO_PROXY="${no_proxy:-${NO_PROXY:-}}"
  export no_proxy="${NO_PROXY:-}"
}

export_http_proxy_for_curl

mkdir -p "${DOWNLOADS_DIR}" "${CURSOR_DIR}" "${STATE_DIR}"

need_refresh() {
  local path="$1"
  [[ "${FORCE_REFRESH_DOWNLOADS}" == "1" ]] || [[ ! -s "${path}" ]]
}

echo "[download 1/3] Google Chrome (.deb)"
CHROME_DEB="${DOWNLOADS_DIR}/google-chrome.deb"
if need_refresh "${CHROME_DEB}"; then
  echo "下载: ${CHROME_DEB_URL} -> ${CHROME_DEB}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 3600 "${CHROME_DEB_URL}" -o "${CHROME_DEB}.part"
  mv -f "${CHROME_DEB}.part" "${CHROME_DEB}"
else
  echo "已存在，跳过: ${CHROME_DEB}"
fi

echo "[download 2/3] Cursor (AppImage)"
CURSOR_TARGET="${CURSOR_DIR}/${CURSOR_APPIMAGE_NAME}"
if need_refresh "${CURSOR_TARGET}"; then
  tmp="${CURSOR_TARGET}.part"
  rm -f "${tmp}"
  cursor_url="${CURSOR_APPIMAGE_URL}"
  if [[ "${cursor_url}" == *'/api/download?'* ]]; then
    cursor_url="$(curl -fsSL "${cursor_url}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloadUrl"])')"
  fi
  if ! curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 "${cursor_url}" -o "${tmp}"; then
    echo "主下载地址失败，尝试 Cursor API 获取直链重试..." >&2
    cursor_url="$(curl -fsSL 'https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable' | python3 -c 'import json,sys; print(json.load(sys.stdin)["downloadUrl"])')"
    curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 20 --max-time 1800 "${cursor_url}" -o "${tmp}"
  fi
  mv -f "${tmp}" "${CURSOR_TARGET}"
  chmod +x "${CURSOR_TARGET}"
else
  echo "已存在，跳过: ${CURSOR_TARGET}"
fi

echo "[download 3/3] 其他说明"
GITHUB_DESKTOP_DEB_URL="${GITHUB_DESKTOP_DEB_URL:-}"
if [[ -n "${GITHUB_DESKTOP_DEB_URL}" ]]; then
  GH_DEB="${DOWNLOADS_DIR}/github-desktop.deb"
  if need_refresh "${GH_DEB}"; then
    echo "下载 GitHub Desktop: ${GITHUB_DESKTOP_DEB_URL}"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 3600 "${GITHUB_DESKTOP_DEB_URL}" -o "${GH_DEB}.part"
    mv -f "${GH_DEB}.part" "${GH_DEB}"
  else
    echo "已存在，跳过: ${GH_DEB}"
  fi
else
  echo "未设置 GITHUB_DESKTOP_DEB_URL，跳过 GitHub Desktop .deb（可在 apps/manifest.env 中配置直链）。"
fi
echo "Claude Code 等 npm 包未自动下载；需要时在容器内自行: npm install -g ${CLAUDE_CODE_NPM_PKG}@${CLAUDE_CODE_NPM_VER}（或使用原 apps/sync-base-apps.sh 全量安装）。"

echo "共享目录下载完成: ${PARENT}/shared_apps"
