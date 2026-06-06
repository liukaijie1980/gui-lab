#!/usr/bin/env bash
# 在运行中的容器内安装 sshd 自启动（镜像未重建时）
set -euo pipefail
for c in "$@"; do
  docker exec -u root "$c" bash -c 'cat >/dockerstartup/custom_startup.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
if command -v sshd >/dev/null 2>&1; then
  sudo mkdir -p /var/run/sshd
  sudo chmod 0755 /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    sudo /usr/sbin/sshd
  fi
fi
exec sleep infinity
EOF
chmod 0755 /dockerstartup/custom_startup.sh
pgrep -x sshd >/dev/null || /usr/sbin/sshd'
  echo "sshd startup: $c"
done
