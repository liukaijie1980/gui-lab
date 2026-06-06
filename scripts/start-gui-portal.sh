#!/usr/bin/env bash
# 启动 GUI 管理台（8787）；若已在运行则跳过。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${GUI_PORTAL_PYTHON:-/home/lkj/anaconda3/bin/python3}"
PORT="${GUI_PORTAL_PORT:-8787}"
LOG="${GUI_PORTAL_LOG:-${ROOT}/gui_portal/nohup.out}"

if pgrep -f "python3 -m gui_portal.app" >/dev/null 2>&1; then
  echo "管理台已在运行 (port ${PORT})"
  exit 0
fi

cd "${ROOT}"
nohup "${PYTHON}" -m gui_portal.app >>"${LOG}" 2>&1 &
sleep 2
if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/"; then
  echo "管理台已启动: http://<本机IP>:${PORT}"
else
  echo "启动可能失败，请查看 ${LOG}" >&2
  exit 1
fi
