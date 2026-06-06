#!/usr/bin/env bash
# 在容器 /usr/local/bin 安装 cursor/claude 包装脚本（重建后该目录会清空，须每次 up/recreate 后执行）
# 用法: ./scripts/install-container-app-wrappers.sh <容器名>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/apps/manifest.env" 2>/dev/null || true
APPIMAGE="${CURSOR_APPIMAGE_NAME:-cursor-latest.AppImage}"

CONTAINER_NAME="${1:-}"
if [[ -z "${CONTAINER_NAME}" ]]; then
  echo "用法: $0 <容器名>" >&2
  exit 2
fi

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  echo "容器不存在: ${CONTAINER_NAME}" >&2
  exit 1
fi

docker exec -u root -e "CURSOR_IMG=${APPIMAGE}" "${CONTAINER_NAME}" bash -c '
  set -euo pipefail
  app="/shared_apps/cursor/${CURSOR_IMG}"
  if [[ ! -x "${app}" ]]; then
    echo "缺少 Cursor AppImage: ${app}" >&2
    exit 1
  fi
  printf "%s\n" "#!/usr/bin/env bash" "exec \"${app}\" --appimage-extract-and-run \"\$@\"" >/usr/local/bin/cursor
  chmod +x /usr/local/bin/cursor
  if [[ -x /shared_apps/node-global/bin/claude ]]; then
    ln -sf /shared_apps/node-global/bin/claude /usr/local/bin/claude
    install -d -m 0755 -o 1000 -g 1000 /home/kasm-user/.local/bin
    ln -sf /shared_apps/node-global/bin/claude /home/kasm-user/.local/bin/claude
  fi
  ls -la /usr/local/bin/
'

echo "已安装 ${CONTAINER_NAME}:/usr/local/bin/cursor"
