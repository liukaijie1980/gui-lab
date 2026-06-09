#!/usr/bin/env bash
# 修复各 GUI 容器 GitHub Desktop：统一启动脚本、AppImage 命名、桌面项、依赖。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTANCES_JSON="${GUI_PORTAL_STATE:-${ROOT}/gui_portal/instances.json}"
RUN_TPL="${ROOT}/gui_portal/run-github-desktop.sh.template"
FIX_SHORTCUTS="${SCRIPT_DIR}/fix-desktop-shortcuts.sh"
SOURCE_APPIMAGE="${GITHUB_DESKTOP_SOURCE_APPIMAGE:-${ROOT}/docker_os/gui-wangyr/home/Apps/github-desktop/GitHubDesktop-linux-x86_64-3.4.13-linux1.AppImage}"

list_containers() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
    return
  fi
  python3 - "${INSTANCES_JSON}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for i in json.load(f).get("instances", []):
        print(i["container_name"])
PY
}

home_for() {
  local cname="$1"
  local h
  h="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/kasm-user"}}{{.Source}}{{end}}{{end}}' "${cname}" 2>/dev/null || true)"
  printf '%s' "${h:-${ROOT}/docker_os/${cname}/home}"
}

fix_container() {
  local cname="$1"
  local home ghd_dir
  home="$(home_for "${cname}")"
  ghd_dir="${home}/Apps/github-desktop"
  mkdir -p "${ghd_dir}"

  echo ">>> ${cname}"

  # 依赖（OAuth 令牌保存）
  if docker inspect "${cname}" >/dev/null 2>&1; then
    if ! docker exec "${cname}" bash --noprofile --norc -c 'command -v gnome-keyring-daemon >/dev/null'; then
      timeout 90 docker exec -u root "${cname}" bash --noprofile --norc -c \
        'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnome-keyring libsecret-1-0 libsecret-tools dbus-x11' \
        2>/dev/null || echo "  warn: apt install gnome-keyring failed/skipped"
    fi
  fi

  # AppImage：补全或修正 .AppImage.bin 后缀
  shopt -s nullglob
  local bins=("${ghd_dir}"/GitHubDesktop-linux-x86_64-*.AppImage.bin)
  shopt -u nullglob
  for b in "${bins[@]}"; do
    local target="${b%.bin}"
    if [[ ! -f "${target}" ]]; then
      mv "${b}" "${target}"
      echo "  renamed $(basename "${b}") -> $(basename "${target}")"
    fi
  done

  shopt -s nullglob
  local imgs=("${ghd_dir}"/GitHubDesktop-linux-x86_64-*.AppImage)
  shopt -u nullglob
  if [[ ${#imgs[@]} -eq 0 ]]; then
    if [[ -f "${SOURCE_APPIMAGE}" ]]; then
      cp -a "${SOURCE_APPIMAGE}" "${ghd_dir}/"
      chmod +x "${ghd_dir}/$(basename "${SOURCE_APPIMAGE}")"
      echo "  copied AppImage from $(basename "${SOURCE_APPIMAGE}")"
    else
      echo "  skip: no AppImage in ${ghd_dir} and no SOURCE_APPIMAGE"
      return 0
    fi
  fi

  cp "${RUN_TPL}" "${ghd_dir}/run-github-desktop.sh"
  chmod +x "${ghd_dir}/run-github-desktop.sh"
  chown -R 1000:1000 "${ghd_dir}" 2>/dev/null || sudo chown -R 1000:1000 "${ghd_dir}"

  if [[ -x "${FIX_SHORTCUTS}" ]]; then
    "${FIX_SHORTCUTS}" "${cname}" >/dev/null
  fi
  echo "  updated run-github-desktop.sh + desktop shortcuts"
}

[[ -f "${RUN_TPL}" ]] || { echo "缺少 ${RUN_TPL}" >&2; exit 1; }

mapfile -t NAMES < <(list_containers "$@")
for n in "${NAMES[@]}"; do
  fix_container "${n}"
done
echo "完成。请在桌面双击 GitHub Desktop 或执行 ~/Apps/github-desktop/run-github-desktop.sh 测试。"
