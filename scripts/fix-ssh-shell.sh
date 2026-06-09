#!/usr/bin/env bash
# 修复 GUI 容器 SSH 体验：默认 bash、登录加载 .bashrc、方向键与提示符正常。
# 用法: ./scripts/fix-ssh-shell.sh [容器名 ...]  不传则处理 instances.json 中全部实例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SNIPPET="${ROOT}/gui_portal/kasm-ssh-bashrc.snippet"
INSTANCES_JSON="${GUI_PORTAL_STATE:-${ROOT}/gui_portal/instances.json}"
MARK_BEGIN='# BEGIN_GUI_PORTAL_SSH'
MARK_END='# END_GUI_PORTAL_SSH'

profile_content() {
  cat <<'EOF'
# GUI 容器 SSH — login shell loads .bashrc
if [ -n "${BASH_VERSION:-}" ]; then
  if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
  fi
fi
EOF
}

patch_bashrc_file() {
  local f="$1"
  local tmp body
  tmp="$(mktemp)"
  if grep -q "${MARK_BEGIN}" "$f" 2>/dev/null; then
    body="$(awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" '
      $0 ~ begin { skip=1; next }
      $0 ~ end { skip=0; next }
      !skip { print }
    ' "$f")"
  else
    body="$(cat "$f")"
  fi
  {
    cat "${SNIPPET}"
    echo "${body}"
  } >"${tmp}"
  mv "${tmp}" "$f"
}

fix_container() {
  local cname="$1"
  local home_dir
  home_dir="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/kasm-user"}}{{.Source}}{{end}}{{end}}' "${cname}" 2>/dev/null || true)"
  if [[ -z "${home_dir}" ]]; then
    home_dir="${ROOT}/docker_os/${cname}/home"
  fi
  if [[ ! -d "${home_dir}" ]]; then
    echo "跳过 ${cname}: 未找到家目录 ${home_dir}" >&2
    return 1
  fi

  echo ">>> ${cname} (home: ${home_dir})"
  docker exec -u root "${cname}" usermod -s /bin/bash kasm-user 2>/dev/null || true

  local brc="${home_dir}/.bashrc"
  local prof="${home_dir}/.profile"
  if [[ ! -f "${brc}" ]]; then
    echo 'source $STARTUPDIR/generate_container_user' >"${brc}"
    chown 1000:1000 "${brc}" 2>/dev/null || sudo chown 1000:1000 "${brc}"
  fi
  patch_bashrc_file "${brc}"
  chown 1000:1000 "${brc}" 2>/dev/null || sudo chown 1000:1000 "${brc}"

  if [[ ! -f "${prof}" ]] || ! grep -q 'GUI 容器 SSH' "${prof}" 2>/dev/null; then
    profile_content >"${prof}"
    chown 1000:1000 "${prof}" 2>/dev/null || sudo chown 1000:1000 "${prof}"
  fi
  echo "  已设置登录 shell=/bin/bash，并更新 .bashrc / .profile"
}

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

[[ -f "${SNIPPET}" ]] || { echo "缺少 ${SNIPPET}" >&2; exit 1; }

mapfile -t NAMES < <(list_containers "$@")
for n in "${NAMES[@]}"; do
  fix_container "${n}"
done
echo "完成。请重新 SSH 登录后体验（无需重建容器）。"
