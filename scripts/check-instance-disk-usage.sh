#!/usr/bin/env bash
#
# check-instance-disk-usage.sh — 检查 GUI 容器持久化目录磁盘占用（软限制）
#
# 用法:
#   ./scripts/check-instance-disk-usage.sh <容器名> <disk_quota_gb> [--stop] [--json]
#
# 统计 docker_os/<容器名>/home 与 persist 的 du 总和；超限时可选 docker stop。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINER_NAME="${1:-}"
DISK_QUOTA_GB="${2:-0}"
DO_STOP=0
JSON_ONLY=0

for arg in "${@:3}"; do
  case "${arg}" in
    --stop) DO_STOP=1 ;;
    --json) JSON_ONLY=1 ;;
  esac
done

if [[ -z "${CONTAINER_NAME}" ]]; then
  echo "用法: $0 <容器名> <disk_quota_gb> [--stop] [--json]" >&2
  exit 2
fi

if ! [[ "${DISK_QUOTA_GB}" =~ ^[0-9]+$ ]] || [[ "${DISK_QUOTA_GB}" -lt 0 ]]; then
  echo "disk_quota_gb 须为非负整数" >&2
  exit 2
fi

_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_dir_bytes() {
  local d="$1"
  if [[ ! -d "${d}" ]]; then
    echo 0
    return
  fi
  # du 遇 Permission denied 时 exit!=0，勿用 || echo 0 以免把用量与 0 拼成两行
  local n
  n="$(du -sb "${d}" 2>/dev/null | awk 'NR==1{print $1; exit}')"
  echo "${n:-0}"
}

HOME_DIR="${ROOT}/docker_os/${CONTAINER_NAME}/home"
PERSIST_DIR="${ROOT}/docker_os/${CONTAINER_NAME}/persist"
home_b="$(_dir_bytes "${HOME_DIR}")"
persist_b="$(_dir_bytes "${PERSIST_DIR}")"
total_b=$((home_b + persist_b))
used_gb=$(awk "BEGIN {printf \"%.3f\", ${total_b} / 1073741824}")

over_limit=false
if [[ "${DISK_QUOTA_GB}" -gt 0 ]]; then
  # 比较 used_gb >= quota
  if awk "BEGIN {exit !(${used_gb} >= ${DISK_QUOTA_GB})}"; then
    over_limit=true
  fi
fi

stopped=false
if [[ "${over_limit}" == "true" && "${DO_STOP}" -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1 && docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    st="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo unknown)"
    if [[ "${st}" == "running" ]]; then
      docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
      stopped=true
    fi
  fi
fi

json="$(cat <<EOF
{
  "container_name": "${CONTAINER_NAME}",
  "used_gb": ${used_gb},
  "quota_gb": ${DISK_QUOTA_GB},
  "over_limit": ${over_limit},
  "stopped": ${stopped},
  "checked_at": "$(_now_iso)",
  "paths": {
    "home": "${HOME_DIR}",
    "persist": "${PERSIST_DIR}"
  }
}
EOF
)"

if [[ "${JSON_ONLY}" -eq 1 ]]; then
  echo "${json}"
else
  echo "${json}" | python3 -m json.tool 2>/dev/null || echo "${json}"
fi

if [[ "${over_limit}" == "true" ]]; then
  exit 1
fi
exit 0
