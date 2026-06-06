#!/usr/bin/env bash
#
# test-resource-limits.sh — 端到端验证容器 CPU/内存/PIDs/磁盘软限制
#
# 用法: ./scripts/test-resource-limits.sh [--keep]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEEP=0
for arg in "$@"; do
  [[ "${arg}" == "--keep" ]] && KEEP=1
done

CONTAINER="gui-reslimit-test"
TEST_PW="TestRes_123456"
CPU_LIMIT="0.5"
MEM_LIMIT="256m"
PIDS_LIMIT="64"
DISK_QUOTA_GB="1"

pass=0
fail=0

log() { echo "[test] $*"; }
ok() { log "PASS: $*"; pass=$((pass + 1)); }
bad() { log "FAIL: $*"; fail=$((fail + 1)); }

cleanup() {
  if [[ "${KEEP}" -eq 1 ]]; then
    log "保留测试容器 ${CONTAINER}（--keep）"
    return
  fi
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${ROOT}/docker_os/${CONTAINER}" 2>/dev/null || true
  log "已清理 ${CONTAINER}"
}

trap cleanup EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "需要 docker" >&2
  exit 2
fi

log "=== 1. 创建低限额测试容器 ==="
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
rm -rf "${ROOT}/docker_os/${CONTAINER}" 2>/dev/null || true

# 找空闲端口
GUI_PORT=""
for p in $(seq 6910 6950); do
  if ! ss -tln 2>/dev/null | grep -q ":${p} " && ! ss -tln 2>/dev/null | grep -q ":$((p - 1000)) "; then
    GUI_PORT="${p}"
    break
  fi
done
if [[ -z "${GUI_PORT}" ]]; then
  echo "无可用测试端口" >&2
  exit 2
fi

export CONTAINER_NAME="${CONTAINER}"
export COMPOSE_PROJECT_NAME="${CONTAINER}"
export GUI_PORT="${GUI_PORT}"
export VNC_NATIVE_PORT="$((GUI_PORT - 1000))"
export SSH_PORT="$((GUI_PORT - 4700))"
export VNC_PW="${TEST_PW}"
export CPU_LIMIT="${CPU_LIMIT}"
export MEM_LIMIT="${MEM_LIMIT}"
export PIDS_LIMIT="${PIDS_LIMIT}"
export NO_GPU="${NO_GPU:-1}"
export RECREATE=1

cd "${ROOT}"
if ! bash ./run-ubuntu22-gui.sh >/tmp/test-reslimit-up.log 2>&1; then
  cat /tmp/test-reslimit-up.log
  bad "run-ubuntu22-gui.sh 启动失败"
  exit 1
fi
ok "容器已创建 (${CONTAINER}, GUI ${GUI_PORT})"

log "=== 2. docker inspect 验证 cgroup ==="
NANO="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${CONTAINER}")"
MEM="$(docker inspect -f '{{.HostConfig.Memory}}' "${CONTAINER}")"
PIDS="$(docker inspect -f '{{.HostConfig.PidsLimit}}' "${CONTAINER}")"

if [[ "${NANO}" == "500000000" ]]; then
  ok "NanoCpus=0.5 (${NANO})"
else
  bad "NanoCpus 期望 500000000，实际 ${NANO}"
fi

if [[ "${MEM}" == "268435456" ]]; then
  ok "Memory=256m (${MEM})"
else
  bad "Memory 期望 268435456，实际 ${MEM}"
fi

if [[ "${PIDS}" == "64" ]]; then
  ok "PidsLimit=64"
else
  bad "PidsLimit 期望 64，实际 ${PIDS}"
fi

log "=== 3. 等待容器就绪 ==="
for _ in $(seq 1 30); do
  st="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || echo missing)"
  [[ "${st}" == "running" ]] && break
  sleep 2
done
if [[ "${st}" != "running" ]]; then
  bad "容器未 running: ${st}"
  docker logs "${CONTAINER}" 2>&1 | tail -20
  exit 1
fi
ok "容器 running"

log "=== 4. 内存超限测试 ==="
# 分配 512MB 应失败或触发 OOM
mem_rc=0
docker exec "${CONTAINER}" python3 -c "bytearray(512*1024*1024)" >/tmp/memtest.out 2>&1 || mem_rc=$?
if [[ "${mem_rc}" -ne 0 ]]; then
  ok "512MB 分配被拒绝或失败 (exit ${mem_rc})"
else
  # 可能 swap 或延迟 OOM；检查容器是否仍存活且内存受限
  if docker inspect -f '{{.State.OOMKilled}}' "${CONTAINER}" 2>/dev/null | grep -q true; then
    ok "容器 OOMKilled"
    docker start "${CONTAINER}" >/dev/null 2>&1 || true
    sleep 5
  else
    bad "512MB 分配未触发限制"
  fi
fi

log "=== 5. 进程数限制测试 ==="
fork_rc=0
docker exec "${CONTAINER}" bash -c '
  for i in $(seq 1 80); do sleep 300 & done
  wait
' >/tmp/forktest.out 2>&1 || fork_rc=$?
if [[ "${fork_rc}" -ne 0 ]]; then
  ok "超过 pids_limit 后 fork 失败 (exit ${fork_rc})"
else
  bad "未触发 pids 限制"
fi
docker exec "${CONTAINER}" bash -c 'kill $(jobs -p) 2>/dev/null' >/dev/null 2>&1 || true

log "=== 6. 磁盘软限制测试 ==="
# 直接写入宿主机挂载目录（bind mount），确保 du 能统计到
mkdir -p "${ROOT}/docker_os/${CONTAINER}/home"
dd if=/dev/zero of="${ROOT}/docker_os/${CONTAINER}/home/reslimit-test-fill" bs=1M count=1200 status=none 2>/dev/null || true
disk_json="$(bash "${SCRIPT_DIR}/check-instance-disk-usage.sh" "${CONTAINER}" "${DISK_QUOTA_GB}" --stop --json || true)"
echo "${disk_json}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('over_limit')==True, d
print('over_limit ok', d.get('used_gb'), 'GB')
" && ok "磁盘超限检测通过" || bad "磁盘超限检测失败: ${disk_json}"

st_after="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null)"
if [[ "${st_after}" == "exited" || "${st_after}" == "stopped" ]]; then
  ok "超限后容器已停止 (${st_after})"
else
  # --stop 应停止 running 容器
  if docker inspect -f '{{.State.Status}}' "${CONTAINER}" | grep -qv running; then
    ok "容器非 running"
  else
    bad "超限后容器仍在 running"
    docker stop "${CONTAINER}" >/dev/null 2>&1 || true
  fi
fi

log "=== 7. 修改资源限额并重建 ==="
export CPU_LIMIT="1"
export MEM_LIMIT="512m"
export PIDS_LIMIT="128"
export RECREATE=1
docker start "${CONTAINER}" >/dev/null 2>&1 || true
sleep 2
bash ./run-ubuntu22-gui.sh >/tmp/test-reslimit-recreate.log 2>&1
NANO2="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${CONTAINER}")"
if [[ "${NANO2}" == "1000000000" ]]; then
  ok "重建后 NanoCpus=1"
else
  bad "重建后 NanoCpus 期望 1000000000，实际 ${NANO2}"
fi

log "=== 结果: ${pass} passed, ${fail} failed ==="
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
exit 0
