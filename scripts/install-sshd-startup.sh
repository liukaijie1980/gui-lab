#!/usr/bin/env bash
# 确保容器内 sshd 已运行。custom_startup 由 run-ubuntu22-gui.sh 挂载 scripts/container-custom-startup.sh，此处仅补启。
set -euo pipefail
for c in "$@"; do
  docker exec -u root "$c" bash -lc '
    set -euo pipefail
    if ! command -v sshd >/dev/null 2>&1; then
      exit 0
    fi
    mkdir -p /var/run/sshd
    chmod 0755 /var/run/sshd
    if ! pgrep -x sshd >/dev/null 2>&1; then
      /usr/sbin/sshd
    fi
  '
  echo "sshd startup: $c"
done
