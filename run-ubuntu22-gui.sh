#!/usr/bin/env bash
#
# run-ubuntu22-gui.sh — 启动 Ubuntu 22.04 + KasmVNC 图形桌面 Docker 容器
#
# 功能概要：
#   - 可选加载本机代理（proxy.sh），并把 localhost/127.0.0.1 映射为 host.docker.internal，
#     避免容器内代理指向错误地址。
#   - 写入 docker_os/<容器名>/.env（每实例独立；并更新根目录 .env.ubuntu22-gui 为最近一次快照），
#     保证 HOME 挂载目录属主为 Kasm 用户 (1000:1000)，并可选写入 KasmVNC 配置（关闭多次输错密码后的 IP 黑名单）。
#   - 挂载 scripts/container-custom-startup.sh 为 /dockerstartup/custom_startup.sh（sshd + 密码自同步）。
#   - 用 docker compose 拉起服务；若容器已存在默认不强制重建（需改端口/密码等时设 RECREATE=1）。
#
# 常用环境变量（均可选，有默认值）：
#   GUI_PORT / VNC_NATIVE_PORT / SSH_PORT / VNC_PW / CONTAINER_NAME / HOME_DIR / COMPOSE_PROJECT_NAME
#   EXTRA_PORTS  额外端口映射，逗号分隔，如 8080:80/tcp,8443:443/udp（写入 docker_os/<容器>/extra-ports.compose.yml）
#   CPU_LIMIT / MEM_LIMIT / MEMSWAP_LIMIT / PIDS_LIMIT  容器资源限制（写入 resource-limits.compose.yml）
#   RECREATE=1  强制重建已有容器
# 参数：
#   $1  可选，容器名（未设 CONTAINER_NAME 时等同该参数）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.ubuntu22-gui.yml"
COMPOSE_NOGPU_FILE="${SCRIPT_DIR}/docker-compose.ubuntu22-gui.nogpu.yml"
LEGACY_ENV_FILE="${SCRIPT_DIR}/.env.ubuntu22-gui"
CUSTOM_STARTUP_SCRIPT="${SCRIPT_DIR}/scripts/container-custom-startup.sh"
RECREATE="${RECREATE:-0}"
NO_GPU="${NO_GPU:-0}"

# ---------------------------------------------------------------------------
# 代理：若存在 proxy.sh 则加载；后续会把宿主机代理地址改写为容器可解析的主机名
# ---------------------------------------------------------------------------
if [[ -f "${HOME}/proxy.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/proxy.sh"
elif [[ -f "/home/lkj/proxy.sh" ]]; then
  # shellcheck source=/dev/null
  source "/home/lkj/proxy.sh"
fi

# 将代理 URL 中的 loopback 替换为 host.docker.internal（Linux 上需 Docker 支持该主机名）
map_for_container() {
  local x="$1"
  x="${x//localhost/host.docker.internal}"
  x="${x//127.0.0.1/host.docker.internal}"
  printf '%s' "$x"
}

pick_proxy() {
  local value="$1"
  if [[ -z "${value}" ]]; then
    printf ''
    return
  fi
  map_for_container "${value}"
}

# 合并常见代理变量名，得到「原始」HTTP(S)/ALL 代理与 NO_PROXY
RAW_HTTP="${http_proxy:-${HTTP_PROXY:-${proxy:-${PROXY:-}}}}"
RAW_HTTPS="${https_proxy:-${HTTPS_PROXY:-${RAW_HTTP}}}"
RAW_ALL="${all_proxy:-${ALL_PROXY:-}}"
_raw_no="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}"
# NO_PROXY 必须包含 host.docker.internal，否则容器访问宿主机服务会被错误地走代理
if [[ -z "${_raw_no}" ]]; then
  RAW_NO_PROXY="localhost,127.0.0.1,::1,host.docker.internal"
elif [[ "${_raw_no}" != *"host.docker.internal"* ]]; then
  RAW_NO_PROXY="${_raw_no},host.docker.internal"
else
  RAW_NO_PROXY="${_raw_no}"
fi
unset _raw_no

HTTP_PROXY_MAPPED="$(pick_proxy "${RAW_HTTP}")"
HTTPS_PROXY_MAPPED="$(pick_proxy "${RAW_HTTPS}")"
ALL_PROXY_MAPPED="$(pick_proxy "${RAW_ALL}")"

# ---------------------------------------------------------------------------
# 容器与挂载默认值（可通过环境变量或首个参数覆盖）
# ---------------------------------------------------------------------------
GUI_PORT="${GUI_PORT:-6901}"
VNC_NATIVE_PORT="${VNC_NATIVE_PORT:-5901}"
# 与 GUI 端口对应：6901→2201（差 4700），便于多实例规划
SSH_PORT="${SSH_PORT:-$((GUI_PORT - 4700))}"
VNC_PW="${VNC_PW:-ChangeMe_123}"
CONTAINER_NAME="${CONTAINER_NAME:-${1:-ubuntu22-gui}}"
# 始终按容器名推导家目录，避免 shell 里残留的 HOME_DIR 导致多实例挂错目录
HOME_DIR="./docker_os/${CONTAINER_NAME}/home"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${CONTAINER_NAME}}"
INSTANCE_DIR="${SCRIPT_DIR}/docker_os/${CONTAINER_NAME}"
ENV_FILE="${INSTANCE_DIR}/.env"

mkdir -p "${INSTANCE_DIR}"

# Kasm 镜像内桌面用户为 kasm-user（UID/GID 1000）。若挂载目录由 Docker 自动创建，常为 root 属主，
# 会导致启动脚本无法向 /home/kasm-user 复制 profile，容器进入重启循环。
#
# 为何会用 sudo：把宿主机目录属主改成 1000:1000 需要 root（chown 到其他 UID）。
# 若以 UID/GID 1000 运行本脚本且 mkdir 新建的目录，通常已是 1000:1000，不会触发 sudo。
#
# SUDO_NONINTERACTIVE=1：systemd/守护进程用 sudo -n；失败则立刻退出并提示（避免卡住要密码）。
_sudo() {
  if [[ "${SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    sudo -n "$@" || {
      echo "错误: 需要 root 执行 chown/mkdir，但 sudo -n 失败（无密码或无 tty）。" >&2
      echo "可选: (1) systemd User= uid 1000；(2) NOPASSWD sudo；(3) 事先 sudo chown -R 1000:1000 对应 HOME_DIR" >&2
      exit 1
    }
  else
    sudo "$@"
  fi
}

ensure_kasm_mount_dirs() {
  local home_abs shared_abs u g
  mkdir -p "${SCRIPT_DIR}/shared_apps"
  shared_abs="$(cd "${SCRIPT_DIR}" && cd shared_apps && pwd)"
  u="$(stat -c '%u' "${shared_abs}")"
  g="$(stat -c '%g' "${shared_abs}")"
  if [[ "${u}" -ne 1000 || "${g}" -ne 1000 ]]; then
    echo "修正 shared_apps 目录属主为 1000:1000（compose 挂载到各容器的 /shared_apps，供 kasm-user 读写）: ${shared_abs}"
    if command -v sudo >/dev/null 2>&1; then
      _sudo chown -R 1000:1000 "${shared_abs}"
    else
      echo "错误: 无法 chown shared_apps。请手动执行: sudo chown -R 1000:1000 ${shared_abs}" >&2
      exit 1
    fi
  fi

  home_abs="$(cd "${SCRIPT_DIR}" && mkdir -p "${HOME_DIR}" && cd "${HOME_DIR}" && pwd)"
  u="$(stat -c '%u' "${home_abs}")"
  g="$(stat -c '%g' "${home_abs}")"
  if [[ "${u}" -ne 1000 || "${g}" -ne 1000 ]]; then
    echo "修正 HOME 挂载目录属主为 1000:1000（Kasm kasm-user）: ${home_abs}"
    if command -v sudo >/dev/null 2>&1; then
      _sudo chown -R 1000:1000 "${home_abs}"
    else
      echo "错误: 无法 chown。请手动执行: sudo chown -R 1000:1000 ${home_abs}" >&2
      exit 1
    fi
  fi

  # KasmVNC 实际读取 ~/.vnc/kasmvnc.yaml（非 ~/.config/kasmvnc/）；多次输错密码会拉黑客户端 IP。
  local kcfg="${home_abs}/.vnc/kasmvnc.yaml"
  if ! grep -qE 'blacklist_threshold:[[:space:]]*0' "${kcfg}" 2>/dev/null; then
    local _write_kasm_cfg=0
    if [[ "$(id -u)" -eq 1000 ]] && [[ "$(id -g)" -eq 1000 ]]; then
      _write_kasm_cfg=1
      mkdir -p "${home_abs}/.vnc"
    elif command -v sudo >/dev/null 2>&1; then
      _write_kasm_cfg=2
      _sudo mkdir -p "${home_abs}/.vnc"
    else
      echo "警告: 未安装 sudo，跳过写入 ${kcfg}；多次输错 Web 密码后若无法连接，请见 README「登录与黑名单」。" >&2
    fi
    if [[ "${_write_kasm_cfg}" -eq 1 ]]; then
      if [[ -f "${kcfg}" ]] && grep -q 'blacklist_threshold:' "${kcfg}"; then
        sed -i 's/blacklist_threshold:.*/    blacklist_threshold: 0/' "${kcfg}"
      else
        tee -a "${kcfg}" >/dev/null <<'EOF'
security:
  brute_force_protection:
    blacklist_threshold: 0
EOF
      fi
      echo "已写入 KasmVNC 配置（关闭多次输错密码后的客户端 IP 黑名单）: ${kcfg}"
    elif [[ "${_write_kasm_cfg}" -eq 2 ]]; then
      if [[ -f "${kcfg}" ]] && grep -q 'blacklist_threshold:' "${kcfg}"; then
        _sudo sed -i 's/blacklist_threshold:.*/    blacklist_threshold: 0/' "${kcfg}"
      else
        _sudo tee -a "${kcfg}" >/dev/null <<'EOF'
security:
  brute_force_protection:
    blacklist_threshold: 0
EOF
      fi
      _sudo chown -R 1000:1000 "${home_abs}/.vnc"
      echo "已写入 KasmVNC 配置（关闭多次输错密码后的客户端 IP 黑名单）: ${kcfg}"
    fi
  fi
}

ensure_kasm_mount_dirs

# ---------------------------------------------------------------------------
# 写出 compose --env-file（每实例 docker_os/<容器名>/.env）；小写/大写代理变量都写一份
# ---------------------------------------------------------------------------
EXTRA_PORTS="${EXTRA_PORTS:-}"
{
  cat <<EOF
GUI_PORT=${GUI_PORT}
VNC_NATIVE_PORT=${VNC_NATIVE_PORT}
SSH_PORT=${SSH_PORT}
VNC_PW=${VNC_PW}
CONTAINER_NAME=${CONTAINER_NAME}
HOME_DIR=${HOME_DIR}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
CPU_LIMIT=${CPU_LIMIT:-}
MEM_LIMIT=${MEM_LIMIT:-}
MEMSWAP_LIMIT=${MEMSWAP_LIMIT:-}
PIDS_LIMIT=${PIDS_LIMIT:-}
HTTP_PROXY=${HTTP_PROXY_MAPPED}
HTTPS_PROXY=${HTTPS_PROXY_MAPPED}
ALL_PROXY=${ALL_PROXY_MAPPED}
NO_PROXY=${RAW_NO_PROXY}
http_proxy=${HTTP_PROXY_MAPPED}
https_proxy=${HTTPS_PROXY_MAPPED}
all_proxy=${ALL_PROXY_MAPPED}
no_proxy=${RAW_NO_PROXY}
EOF
  if [[ -n "${EXTRA_PORTS}" ]]; then
    echo "EXTRA_PORTS=${EXTRA_PORTS}"
  fi
} > "${ENV_FILE}"

{
  echo "# 最近启动实例 ${CONTAINER_NAME} 的快照；权威配置见 docker_os/${CONTAINER_NAME}/.env"
  cat "${ENV_FILE}"
} > "${LEGACY_ENV_FILE}"

# docker compose 展开 compose 里的 ${HTTP_PROXY}、${http_proxy} 等时，会优先使用**当前 shell 已导出**的变量；
# 本脚本前面 source 过 proxy.sh，其中多为 localhost/127.0.0.1，会覆盖 --env-file 里的映射值，导致容器内代理仍指向 localhost。
# 因此在执行 compose 前，用刚写入的 .env 覆盖当前 shell 的代理相关变量（以及 GUI/VNC 等 compose 插值所需项）。
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

echo "已生成 ${ENV_FILE}（并更新 ${LEGACY_ENV_FILE} 快照）"
_extra_summary=""
if [[ -n "${EXTRA_PORTS:-}" ]]; then
  _extra_summary="，额外端口: ${EXTRA_PORTS}"
fi
echo "将启动 Ubuntu 22.04 图形桌面容器: ${CONTAINER_NAME}（Web: ${GUI_PORT}，VNC: ${VNC_NATIVE_PORT}，SSH: ${SSH_PORT}${_extra_summary}，项目: ${COMPOSE_PROJECT_NAME}）"

# ---------------------------------------------------------------------------
# 额外端口映射：生成 compose 覆盖（与主 compose 的 ports 列表拼接）
# ---------------------------------------------------------------------------
PORTS_OVERRIDE="${INSTANCE_DIR}/extra-ports.compose.yml"
compose_extra=()
if [[ -n "${EXTRA_PORTS}" ]]; then
  mkdir -p "$(dirname "${PORTS_OVERRIDE}")"
  {
    echo "services:"
    echo "  ubuntu22-gui:"
    echo "    ports:"
    IFS=',' read -ra _maps <<< "${EXTRA_PORTS}"
    for m in "${_maps[@]}"; do
      m="${m#"${m%%[![:space:]]*}"}"
      m="${m%"${m##*[![:space:]]}"}"
      [[ -z "${m}" ]] && continue
      if [[ "${m}" == *"/"* ]]; then
        hp="${m%%/*}"
        proto="${m##*/}"
        echo "      - \"${hp}/${proto}\""
      else
        echo "      - \"${m}\""
      fi
    done
  } > "${PORTS_OVERRIDE}"
  compose_extra+=(-f "${PORTS_OVERRIDE}")
elif [[ -f "${PORTS_OVERRIDE}" ]]; then
  rm -f "${PORTS_OVERRIDE}"
fi

# ---------------------------------------------------------------------------
# 资源限制：生成 compose 覆盖（CPU / 内存 / 进程数）
# ---------------------------------------------------------------------------
CPU_LIMIT="${CPU_LIMIT:-}"
MEM_LIMIT="${MEM_LIMIT:-}"
MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-}"
PIDS_LIMIT="${PIDS_LIMIT:-}"
RESOURCE_OVERRIDE="${INSTANCE_DIR}/resource-limits.compose.yml"
compose_resource=()
_has_resource_limit=0
if [[ -n "${CPU_LIMIT}" || -n "${MEM_LIMIT}" || -n "${PIDS_LIMIT}" ]]; then
  _has_resource_limit=1
fi
if [[ "${_has_resource_limit}" -eq 1 ]]; then
  mkdir -p "$(dirname "${RESOURCE_OVERRIDE}")"
  {
    echo "services:"
    echo "  ubuntu22-gui:"
    if [[ -n "${CPU_LIMIT}" ]]; then
      echo "    cpus: \"${CPU_LIMIT}\""
    fi
    if [[ -n "${MEM_LIMIT}" ]]; then
      echo "    mem_limit: ${MEM_LIMIT}"
      if [[ -n "${MEMSWAP_LIMIT}" ]]; then
        echo "    memswap_limit: ${MEMSWAP_LIMIT}"
      else
        echo "    memswap_limit: ${MEM_LIMIT}"
      fi
    fi
    if [[ -n "${PIDS_LIMIT}" ]]; then
      echo "    pids_limit: ${PIDS_LIMIT}"
    fi
  } > "${RESOURCE_OVERRIDE}"
  compose_resource+=(-f "${RESOURCE_OVERRIDE}")
  _res_summary="CPU=${CPU_LIMIT:-∞} MEM=${MEM_LIMIT:-∞} PIDS=${PIDS_LIMIT:-∞}"
  echo "资源限制: ${_res_summary}"
elif [[ -f "${RESOURCE_OVERRIDE}" ]]; then
  rm -f "${RESOURCE_OVERRIDE}"
fi

# ---------------------------------------------------------------------------
# custom_startup：挂载宿主机脚本（sshd + VNC_PW 同步），无需重建镜像即可生效
# ---------------------------------------------------------------------------
STARTUP_OVERRIDE="${INSTANCE_DIR}/custom-startup.compose.yml"
compose_startup=()
if [[ -f "${CUSTOM_STARTUP_SCRIPT}" ]]; then
  chmod +x "${CUSTOM_STARTUP_SCRIPT}" 2>/dev/null || true
  _startup_abs="$(cd "${SCRIPT_DIR}" && cd scripts && pwd)/container-custom-startup.sh"
  {
    echo "services:"
    echo "  ubuntu22-gui:"
    echo "    volumes:"
    echo "      - ${_startup_abs}:/dockerstartup/custom_startup.sh:ro"
  } > "${STARTUP_OVERRIDE}"
  compose_startup+=(-f "${STARTUP_OVERRIDE}")
  echo "已加载 custom_startup 挂载: ${CUSTOM_STARTUP_SCRIPT}"
fi

# ---------------------------------------------------------------------------
# 额外卷挂载：若存在 docker_os/<容器名>/extra-volumes.compose.yml 则自动合并
# ---------------------------------------------------------------------------
VOLUMES_OVERRIDE="${INSTANCE_DIR}/extra-volumes.compose.yml"
compose_volumes=()
if [[ -f "${VOLUMES_OVERRIDE}" ]]; then
  compose_volumes+=(-f "${VOLUMES_OVERRIDE}")
  echo "已加载额外卷配置: ${VOLUMES_OVERRIDE}"
fi

# ---------------------------------------------------------------------------
# 拉起容器：已存在时默认不 --force-recreate（避免每次冷启动与重复安装）。
# 需改端口/环境并重建实例时: RECREATE=1 ./run-ubuntu22-gui.sh
# 宿主机 NVIDIA 异常时可: NO_GPU=1 RECREATE=1 ./run-ubuntu22-gui.sh
# ---------------------------------------------------------------------------
compose_files=(-f "${COMPOSE_FILE}")
if [[ ${#compose_extra[@]} -gt 0 ]]; then
  compose_files+=("${compose_extra[@]}")
fi
if [[ ${#compose_resource[@]} -gt 0 ]]; then
  compose_files+=("${compose_resource[@]}")
fi
if [[ ${#compose_volumes[@]} -gt 0 ]]; then
  compose_files+=("${compose_volumes[@]}")
fi
if [[ ${#compose_startup[@]} -gt 0 ]]; then
  compose_files+=("${compose_startup[@]}")
fi
if [[ "${NO_GPU}" == "1" ]]; then
  compose_files+=(-f "${COMPOSE_NOGPU_FILE}")
  echo "NO_GPU=1: 本次不使用 GPU（nvidia-container-cli 异常时的临时方案）"
fi
if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
  if [[ "${RECREATE}" == "1" ]]; then
    echo "RECREATE=1: 将重新创建容器（以应用最新 .env 与 compose 配置）..."
    docker compose -p "${COMPOSE_PROJECT_NAME}" --env-file "${ENV_FILE}" "${compose_files[@]}" up -d --force-recreate
  else
    echo "容器 ${CONTAINER_NAME} 已存在: 仅 ensure 运行中（不强制重建）。要应用新端口/密码等并重建请设 RECREATE=1。"
    docker compose -p "${COMPOSE_PROJECT_NAME}" --env-file "${ENV_FILE}" "${compose_files[@]}" up -d
  fi
else
  docker compose -p "${COMPOSE_PROJECT_NAME}" --env-file "${ENV_FILE}" "${compose_files[@]}" up -d
fi
echo "访问地址: https://<服务器IP>:${GUI_PORT}"
echo "Web 登录用户名: kasm_user（下划线；也接受 kasm-user）  密码: （本次 VNC_PW）"
echo "VNC 客户端连接: <服务器IP>:${VNC_NATIVE_PORT}"
echo "SSH: ssh -p ${SSH_PORT} kasm-user@<服务器IP>  （Linux 密码见迁移说明或 instances.json 中的 vnc_pw）"

SYNC_KASM_PW="${SCRIPT_DIR}/scripts/sync-kasm-web-password.sh"
if [[ -x "${SYNC_KASM_PW}" ]]; then
  "${SYNC_KASM_PW}" "${CONTAINER_NAME}" "${VNC_PW}" || \
    echo "警告: Kasm Web 密码同步未完成（容器可能仍在启动，稍后在管理台点「启动」重试）。" >&2
fi

# /usr/local/bin 不在持久化卷内，重建后会清空；每次 up/recreate 后安装 cursor/claude 包装脚本
INSTALL_WRAPPERS="${SCRIPT_DIR}/scripts/install-container-app-wrappers.sh"
if [[ -x "${INSTALL_WRAPPERS}" ]]; then
  for _w in $(seq 1 45); do
    if docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q true; then
      break
    fi
    sleep 2
  done
  if ! "${INSTALL_WRAPPERS}" "${CONTAINER_NAME}"; then
    echo "警告: Cursor 包装脚本安装失败（可稍后执行 ${INSTALL_WRAPPERS} ${CONTAINER_NAME}）。" >&2
  fi
fi
