#!/usr/bin/env bash
#
# 为已存在的 GUI 容器启用 SSH，不删除用户数据。
#
# 数据安全说明：
#   - 家目录 ./docker_os/<容器名>/home、shared_apps、persist 均为卷挂载，重建容器不会丢失。
#   - 仅会短暂中断该容器（约 10–60 秒），请在业务低峰逐台执行。
#   - 未挂载到卷内的临时文件会随重建丢失（用户工作区一般在 home 卷内）。
#
# 用法（在 /data 下，需能执行 docker / docker compose）：
#   ./scripts/enable-ssh-existing.sh              # 处理 instances.json 中全部实例
#   ./scripts/enable-ssh-existing.sh gui-lkj      # 仅处理指定容器
#   DRY_RUN=1 ./scripts/enable-ssh-existing.sh    # 只打印将执行的操作
#   SKIP_BUILD=1 ./scripts/enable-ssh-existing.sh # 跳过镜像构建（镜像已含 openssh 时）
#   SSH_SYNC_VNC_PW=0 ...                         # 不把 VNC 密码同步为 Linux SSH 密码
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTANCES_JSON="${GUI_PORTAL_STATE:-${ROOT}/gui_portal/instances.json}"
RUN_SCRIPT="${ROOT}/run-ubuntu22-gui.sh"
COMPOSE_FILE="${ROOT}/docker-compose.ubuntu22-gui.yml"
COMPOSE_NOGPU_FILE="${ROOT}/docker-compose.ubuntu22-gui.nogpu.yml"
DRY_RUN="${DRY_RUN:-0}"
SKIP_BUILD="${SKIP_BUILD:-1}"
SSH_SYNC_VNC_PW="${SSH_SYNC_VNC_PW:-1}"
NO_GPU="${NO_GPU:-0}"

gui_to_ssh() {
  printf '%s' "$(( $1 - 4700 ))"
}

set_linux_password() {
  local cname="$1" pw="$2"
  if [[ "${SSH_SYNC_VNC_PW}" != "1" ]]; then
    echo "  [跳过] 未设置 SSH_SYNC_VNC_PW=1，不写入 kasm-user Linux 密码（请自行配置公钥或 passwd）"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] docker exec 设置 ${cname} 的 kasm-user Linux 密码"
    return 0
  fi
  if ! docker inspect "${cname}" >/dev/null 2>&1; then
    echo "  警告: 容器 ${cname} 不存在，跳过 chpasswd（重建后请再执行一次或手动 passwd）" >&2
    return 0
  fi
  # chpasswd 需 root；密码含特殊字符时用环境变量传递
  docker exec -u root -e "LINUX_PW=${pw}" "${cname}" bash -lc \
    'echo "kasm-user:${LINUX_PW}" | chpasswd' || {
    echo "  警告: chpasswd 失败，可在容器内执行: passwd" >&2
    return 0
  }
  echo "  已同步 kasm-user Linux 密码（与 VNC_PW 相同，建议登录后 passwd 修改）"
}

recreate_with_ssh() {
  local cname="$1" gui="$2" vnc="$3" ssh_port="$4" vnc_pw="$5"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  [dry-run] RECREATE=1 NO_GPU=${NO_GPU} CONTAINER_NAME=${cname} GUI_PORT=${gui} VNC_NATIVE_PORT=${vnc} SSH_PORT=${ssh_port} ./run-ubuntu22-gui.sh"
    return 0
  fi
  (
    cd "${ROOT}"
    export CONTAINER_NAME="${cname}"
    export COMPOSE_PROJECT_NAME="${cname}"
    unset HOME_DIR
    export GUI_PORT="${gui}"
    export VNC_NATIVE_PORT="${vnc}"
    export SSH_PORT="${ssh_port}"
    export VNC_PW="${vnc_pw}"
    export RECREATE=1
    export NO_GPU="${NO_GPU}"
    "${RUN_SCRIPT}"
  )
}

update_instances_json_ssh_ports() {
  if [[ ! -f "${INSTANCES_JSON}" ]] || [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  python3 - "${INSTANCES_JSON}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
for inst in data.get("instances", []):
    g = int(inst["gui_port"])
    inst["ssh_port"] = g - 4700
    inst.setdefault("ssh_login_user", "kasm-user")
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"已更新 {path} 中的 ssh_port 字段")
PY
}

build_image_if_needed() {
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    echo "SKIP_BUILD=1：跳过镜像构建（若 SSH 无法连接，请去掉 SKIP_BUILD 重新执行）"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] docker compose build ubuntu22-gui"
    return 0
  fi
  echo "正在构建含 openssh-server 的镜像（首次可能较久）..."
  (
    cd "${ROOT}"
    docker compose -f "${COMPOSE_FILE}" build ubuntu22-gui
  )
}

load_instances() {
  if [[ ! -f "${INSTANCES_JSON}" ]]; then
    echo "错误: 找不到 ${INSTANCES_JSON}" >&2
    exit 1
  fi
  python3 - "${INSTANCES_JSON}" "$@" <<'PY'
import json, sys
path, *only = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
want = set(only) if only else None
for inst in data.get("instances", []):
    c = inst["container_name"]
    if want and c not in want:
        continue
    print("|".join([
        c,
        str(inst["gui_port"]),
        str(inst.get("vnc_native_port", int(inst["gui_port"]) - 1000)),
        inst.get("vnc_pw", ""),
    ]))
PY
}

echo "=== GUI 容器 SSH 迁移（数据卷保留，仅重建容器以映射 22 端口）==="
echo "instances: ${INSTANCES_JSON}"
echo "DRY_RUN=${DRY_RUN} SKIP_BUILD=${SKIP_BUILD} SSH_SYNC_VNC_PW=${SSH_SYNC_VNC_PW}"
echo ""

build_image_if_needed

mapfile -t ROWS < <(load_instances "$@")
if [[ ${#ROWS[@]} -eq 0 ]]; then
  echo "没有匹配的实例。" >&2
  exit 1
fi

for row in "${ROWS[@]}"; do
  IFS='|' read -r cname gui vnc vnc_pw <<<"${row}"
  ssh_port="$(gui_to_ssh "${gui}")"
  echo ">>> ${cname}  GUI=${gui} VNC=${vnc} SSH=${ssh_port}"
  if [[ -z "${vnc_pw}" ]]; then
    echo "  错误: instances.json 中无 vnc_pw，无法安全重建。请补全后重试。" >&2
    exit 1
  fi
  if [[ "${#vnc_pw}" -lt 6 ]]; then
    echo "  错误: vnc_pw 少于 6 位（镜像要求）" >&2
    exit 1
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -tln | grep -q ":${ssh_port} "; then
      echo "  警告: 宿主机端口 ${ssh_port} 已被占用，请调整 GUI 端口或手动指定 SSH_PORT" >&2
    fi
  fi
  set_linux_password "${cname}" "${vnc_pw}"
  recreate_with_ssh "${cname}" "${gui}" "${vnc}" "${ssh_port}" "${vnc_pw}"
  set_linux_password "${cname}" "${vnc_pw}"
  echo "  完成: ssh -p ${ssh_port} kasm-user@<服务器IP>"
  echo ""
done

update_instances_json_ssh_ports
echo "全部处理完毕。请放行防火墙 TCP ${ssh_port} 等对应端口，并通知用户："
echo "  - SSH 用户: kasm-user（横线，不是浏览器用的 kasm_user）"
echo "  - 初始 Linux 密码默认与创建实例时的 VNC 密码相同（可用 SSH_SYNC_VNC_PW=0 跳过同步）"
echo "  - 公钥可写入持久化目录 ~/.ssh/authorized_keys（推荐）"
