#!/usr/bin/env bash
# 修正容器内 sshd 误监听宿主机 SSH 端口（如 Port 2201）的问题。
# compose 映射为 ${SSH_PORT}:22，容器内 sshd 必须监听 22。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTANCES_JSON="${GUI_PORTAL_STATE:-${ROOT}/gui_portal/instances.json}"

fix_one() {
  local cname="$1"
  if ! docker inspect "${cname}" >/dev/null 2>&1; then
    echo "跳过（不存在）: ${cname}" >&2
    return 0
  fi
  docker exec -u root "${cname}" bash -lc '
    set -euo pipefail
    cfg=/etc/ssh/sshd_config
    if grep -qE "^Port [0-9]+$" "$cfg"; then
      bad=$(grep -E "^Port [0-9]+$" "$cfg" | awk "{print \$2}")
      if [[ "$bad" != "22" ]]; then
        sed -i "s/^Port ${bad}/# Port ${bad} (removed: host maps to container :22)/" "$cfg"
        echo "  已移除错误 Port ${bad}，改回默认 22"
        pkill -x sshd 2>/dev/null || true
        sleep 1
        mkdir -p /var/run/sshd && chmod 0755 /var/run/sshd
        /usr/sbin/sshd
      else
        echo "  Port 22，无需修改"
      fi
    else
      echo "  未显式设置 Port，使用默认 22"
    fi
    ss -tlnp 2>/dev/null | grep -E ":22 |:22$" | head -1 || true
  '
  echo "完成: ${cname}"
}

if [[ $# -gt 0 ]]; then
  for c in "$@"; do
    fix_one "$c"
  done
  exit 0
fi

if [[ -f "${INSTANCES_JSON}" ]]; then
  python3 - "${INSTANCES_JSON}" <<'PY'
import json, subprocess, sys
path = sys.argv[1]
with open(path) as f:
    for inst in json.load(f).get("instances", []):
        print(inst["container_name"])
PY
  | while read -r c; do
    [[ -n "$c" ]] && fix_one "$c"
  done
else
  echo "用法: $0 <容器名> ...  或配置 ${INSTANCES_JSON}" >&2
  exit 1
fi
