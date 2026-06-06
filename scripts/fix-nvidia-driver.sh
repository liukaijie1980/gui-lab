#!/usr/bin/env bash
#
# 修复 NVML driver/library version mismatch，并将 NVIDIA 580.159.03 驱动锁定。
#
# 典型原因：apt 升级了用户态库/DKMS 模块，但旧版内核模块仍驻留内存。
#
# 用法:
#   sudo ./scripts/fix-nvidia-driver.sh
#
# 可选环境变量:
#   SKIP_DOCKER_STOP=1   不停止 Docker（若无法卸载模块则改为提示重启）
#   REBOOT=1             在线重载失败时自动重启（非交互）
#   DRY_RUN=1            仅打印将执行的操作
#
set -euo pipefail

TARGET_VERSION="580.159.03-0ubuntu0.22.04.1"
TARGET_SHORT="580.159.03"
PIN_FILE="/etc/apt/preferences.d/nvidia-driver-pin-580159"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_TEMPLATE="${SCRIPT_DIR}/host/nvidia-driver-pin-580159"

log() { echo "[fix-nvidia-driver] $*"; }
die() { echo "[fix-nvidia-driver] 错误: $*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -E bash "$0" "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    exec pkexec env REBOOT="${REBOOT:-}" SKIP_DOCKER_STOP="${SKIP_DOCKER_STOP:-}" DRY_RUN="${DRY_RUN:-}" bash "$0" "$@"
  else
    exec sudo -E bash "$0" "$@"
  fi
fi

SHIFTKEY_REPO="/etc/apt/sources.list.d/packagecloud-shiftkey-desktop.list"
SHIFTKEY_REPO_DISABLED="${SHIFTKEY_REPO}.disabled-by-fix-nvidia-driver"
RESTORE_SHIFTKEY_REPO=0
if [[ -f "${SHIFTKEY_REPO}" ]]; then
  log "检测到失效第三方源，临时禁用: ${SHIFTKEY_REPO}"
  mv "${SHIFTKEY_REPO}" "${SHIFTKEY_REPO_DISABLED}"
  RESTORE_SHIFTKEY_REPO=1
fi
cleanup() {
  if [[ "${RESTORE_SHIFTKEY_REPO}" -eq 1 && -f "${SHIFTKEY_REPO_DISABLED}" ]]; then
    mv "${SHIFTKEY_REPO_DISABLED}" "${SHIFTKEY_REPO}"
    log "已恢复第三方源文件: ${SHIFTKEY_REPO}"
  fi
}
trap cleanup EXIT

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "未找到 nvidia-smi，请先安装 nvidia-driver-580"
fi

loaded_ver=""
if [[ -r /proc/driver/nvidia/version ]]; then
  loaded_ver="$(sed -n 's/.*Kernel Module  \([0-9.]*\).*/\1/p' /proc/driver/nvidia/version || true)"
fi
userspace_ver="$(modinfo nvidia 2>/dev/null | awk -F':[[:space:]]+' '/^version:/ {print $2; exit}')"

log "已加载内核模块版本: ${loaded_ver:-未知}"
log "磁盘/DKMS 模块版本: ${userspace_ver:-未知}"
log "目标锁定版本: ${TARGET_VERSION}"

# 1) 确保 DKMS 模块已为当前内核构建
if command -v dkms >/dev/null 2>&1; then
  log "检查 DKMS 状态..."
  run dkms install "nvidia/${TARGET_SHORT}" -k "$(uname -r)" || true
  run dkms status "nvidia/${TARGET_SHORT}" || true
fi

# 2) 确保用户态包版本一致
log "对齐已安装的 NVIDIA 580 包到 ${TARGET_VERSION}..."
run apt-get update -qq
nvidia_pkgs="$(dpkg-query -W -f='${Package}\n' 'nvidia-*-580' 'libnvidia-*-580' 'xserver-xorg-video-nvidia-580' 2>/dev/null | sort -u || true)"
if [[ -n "${nvidia_pkgs}" ]]; then
  # shellcheck disable=SC2086
  run apt-get install -y --allow-downgrades ${nvidia_pkgs}="${TARGET_VERSION}"
fi

# 3) 尝试在线重载内核模块
reload_modules() {
  log "卸载 NVIDIA 内核模块..."
  run modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
  log "加载 NVIDIA 内核模块..."
  run modprobe nvidia
  run modprobe nvidia_modeset
  run modprobe nvidia_drm
  run modprobe nvidia_uvm
}

docker_stopped=0
stop_docker_if_needed() {
  if [[ "${SKIP_DOCKER_STOP:-0}" == "1" ]]; then
    return 0
  fi
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "停止 Docker 以释放 GPU 引用..."
    run systemctl stop docker.socket docker
    docker_stopped=1
  fi
}

start_docker_if_stopped() {
  if [[ "${docker_stopped}" -eq 1 ]]; then
    log "重新启动 Docker..."
    run systemctl start docker
  fi
}

stop_docker_if_needed
set +e
reload_modules
reload_rc=$?
set -e
start_docker_if_stopped

if [[ "${reload_rc}" -ne 0 ]]; then
  log "在线重载模块失败（通常因有进程仍占用 GPU）。"
  needs_reboot=1
else
  log "内核模块重载成功。"
  needs_reboot=0
fi

# 4) 写入 apt pin（防止 apt upgrade 自动升级驱动）
log "写入 apt 版本锁定: ${PIN_FILE}"
if [[ -f "${PIN_TEMPLATE}" ]]; then
  run install -m 0644 "${PIN_TEMPLATE}" "${PIN_FILE}"
else
  run tee "${PIN_FILE}" >/dev/null <<EOF
# 锁定 NVIDIA 580 驱动到 ${TARGET_VERSION}，防止 apt upgrade 造成 driver/library mismatch
Package: nvidia-*-580 libnvidia-*-580 xserver-xorg-video-nvidia-580 nvidia-firmware-580-*
Pin: version ${TARGET_VERSION}
Pin-Priority: 1001
EOF
fi

# 6) apt-mark hold
log "apt-mark hold 全部 NVIDIA 580 相关包..."
while IFS= read -r pkg; do
  [[ -n "${pkg}" ]] || continue
  run apt-mark hold "${pkg}"
done < <(dpkg-query -W -f='${Package}\n' 'nvidia-*-580' 'libnvidia-*-580' 'xserver-xorg-video-nvidia-580' 2>/dev/null | sort -u)

log "当前 hold 状态:"
apt-mark showhold | grep -E 'nvidia|libnvidia' || true

# 7) 验证
if nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi 正常:"
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
elif [[ "${needs_reboot:-0}" -eq 1 ]]; then
  log "nvidia-smi 仍异常：用户态库 ${TARGET_SHORT} 已就绪，但内存中内核模块仍为 ${loaded_ver:-旧版}。"
  if [[ "${REBOOT:-0}" == "1" ]]; then
    log "REBOOT=1，即将重启以加载新内核模块..."
    run reboot
    exit 0
  fi
  log "驱动包已锁定。请维护窗口执行: sudo REBOOT=1 $0"
  log "或: sudo reboot   # 重启后 nvidia-smi 应恢复正常"
  exit 1
else
  log "警告: nvidia-smi 仍异常，请检查 dmesg | grep -i nvidia"
  exit 1
fi

log "完成。升级系统前可用 apt-mark unhold 解除锁定。"
