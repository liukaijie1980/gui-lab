#!/usr/bin/env bash
#
# limit-container-bandwidth.sh — 宿主机 tc 限制 Docker 容器互联网上下行带宽
#
# 上行（EGRESS）：容器 → 互联网（上传）
# 下行（INGRESS）：互联网 → 容器（下载）
#
# 速率单位 Mbps，支持 0.1 精度（如 20、15.5、0.1）。
#
# 用法:
#   limit-container-bandwidth.sh apply <容器名> [上行Mbps] [下行Mbps]
#     省略或传空字符串表示该方向不限速。
#   limit-container-bandwidth.sh clear <容器名>
#     清除该容器记录的限速规则（容器未运行时按 state 文件清理残留 IFB）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif [[ "${SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    sudo -n "$@" || {
      echo "错误: 带宽限制需要 root，但 sudo -n 失败。" >&2
      return 1
    }
  else
    sudo "$@"
  fi
}

_sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

validate_mbit() {
  local val="$1" label="$2"
  if [[ -z "${val}" ]]; then
    return 0
  fi
  if [[ ! "${val}" =~ ^[0-9]+(\.[0-9])?$ ]]; then
    echo "错误: ${label} 须为 Mbps 数字，精确到 0.1（如 20、15.5、0.1），当前: ${val}" >&2
    return 1
  fi
  if ! awk -v v="${val}" 'BEGIN { exit !(v + 0 >= 0.1) }'; then
    echo "错误: ${label} 须 >= 0.1 Mbps，当前: ${val}" >&2
    return 1
  fi
}

tc_burst_kbit() {
  local rate_mbit="$1"
  awk -v r="${rate_mbit}" 'BEGIN {
    b = r * 32;
    if (b < 15) b = 15;
    if (b > 512) b = 512;
    printf "%dkbit", int(b);
  }'
}

state_file_for() {
  printf '%s/docker_os/%s/bandwidth.state' "${ROOT}" "$1"
}

read_state() {
  local sf="$1"
  [[ -f "${sf}" ]] || return 1
  # shellcheck disable=SC1090
  source "${sf}"
}

write_state() {
  local sf="$1" container="$2" veth="$3" ifb="$4" egress="$5" ingress="$6"
  mkdir -p "$(dirname "${sf}")"
  cat >"${sf}" <<EOF
CONTAINER=${container}
VETH=${veth}
IFB=${ifb}
EGRESS_MBIT=${egress}
INGRESS_MBIT=${ingress}
EOF
}

remove_state() {
  local sf="$1"
  rm -f "${sf}"
}

clear_veth_tc() {
  local veth="$1"
  [[ -n "${veth}" ]] || return 0
  if ip link show "${veth}" >/dev/null 2>&1; then
    _sudo tc qdisc del dev "${veth}" root 2>/dev/null || true
    _sudo tc qdisc del dev "${veth}" ingress 2>/dev/null || true
  fi
}

clear_ifb() {
  local ifb="$1"
  [[ -n "${ifb}" ]] || return 0
  if ip link show "${ifb}" >/dev/null 2>&1; then
    _sudo tc qdisc del dev "${ifb}" root 2>/dev/null || true
    _sudo ip link del "${ifb}" 2>/dev/null || true
  fi
}

container_veth() {
  local container="$1"
  local pid iface iflink veth attempt

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    pid="$(docker inspect -f '{{.State.Pid}}' "${container}" 2>/dev/null || true)"
    if [[ -z "${pid}" || "${pid}" == "0" ]]; then
      sleep 1
      continue
    fi

    iface="$(_sudo nsenter -t "${pid}" -n sh -c \
      "ip -o link | awk -F': ' '\$2 !~ /^lo/ {gsub(/@.*/, \"\", \$2); print \$2; exit}'" 2>/dev/null || true)"
    if [[ -z "${iface}" ]]; then
      sleep 1
      continue
    fi

    iflink="$(_sudo nsenter -t "${pid}" -n cat "/sys/class/net/${iface}/iflink" 2>/dev/null || true)"
    if [[ -z "${iflink}" ]]; then
      iflink="$(_sudo nsenter -t "${pid}" -n ip -o link show "${iface}" 2>/dev/null \
        | sed -n 's/.*@if\([0-9]*\).*/\1/p' | head -1)"
    fi
    if [[ -z "${iflink}" ]]; then
      sleep 1
      continue
    fi

    veth="$(ip -o link | awk -F': ' -v n="${iflink}" '$1 == n {gsub(/@.*/, "", $2); print $2; exit}')"
    if [[ -n "${veth}" ]]; then
      printf '%s' "${veth}"
      return 0
    fi
    sleep 1
  done

  echo "错误: 无法定位 ${container} 的宿主机 veth（容器可能仍在启动）。" >&2
  return 1
}

ensure_ifb_module() {
  _sudo modprobe ifb numifbs=8 2>/dev/null || _sudo modprobe ifb 2>/dev/null || true
}

apply_egress() {
  local veth="$1" ifb="$2" rate_mbit="$3"
  local burst
  burst="$(tc_burst_kbit "${rate_mbit}")"

  ensure_ifb_module
  _sudo ip link add "${ifb}" type ifb 2>/dev/null || true
  _sudo ip link set "${ifb}" up

  _sudo tc qdisc add dev "${veth}" handle ffff: ingress
  _sudo tc filter add dev "${veth}" parent ffff: protocol all u32 match u32 0 0 \
    action mirred egress redirect dev "${ifb}"
  _sudo tc qdisc add dev "${ifb}" root tbf rate "${rate_mbit}mbit" burst "${burst}" latency 400ms
}

apply_ingress() {
  local veth="$1" rate_mbit="$2"
  local burst
  burst="$(tc_burst_kbit "${rate_mbit}")"

  _sudo tc qdisc add dev "${veth}" root tbf rate "${rate_mbit}mbit" burst "${burst}" latency 400ms
}

cmd_clear() {
  local container="$1"
  local sf veth="" ifb=""

  sf="$(state_file_for "${container}")"
  if read_state "${sf}"; then
    veth="${VETH:-}"
    ifb="${IFB:-}"
  fi

  if [[ -z "${veth}" ]]; then
    if veth="$(container_veth "${container}" 2>/dev/null)"; then
      :
    else
      veth=""
    fi
  fi

  clear_veth_tc "${veth}"
  clear_ifb "${ifb}"
  remove_state "${sf}"
  echo "已清除 ${container} 的带宽限制。"
}

cmd_apply() {
  local container="$1"
  local egress="${2:-}"
  local ingress="${3:-}"
  local sf veth ifb safe_name old_ifb=""

  validate_mbit "${egress}" "上行带宽 EGRESS_MBIT"
  validate_mbit "${ingress}" "下行带宽 INGRESS_MBIT"

  sf="$(state_file_for "${container}")"
  if read_state "${sf}"; then
    old_ifb="${IFB:-}"
  fi

  if [[ -z "${egress}" && -z "${ingress}" ]]; then
    cmd_clear "${container}"
    return 0
  fi

  veth="$(container_veth "${container}")"
  safe_name="$(_sanitize_name "${container}")"
  ifb="ifb-${safe_name}"

  clear_veth_tc "${veth}"
  if [[ -n "${old_ifb}" && "${old_ifb}" != "${ifb}" ]]; then
    clear_ifb "${old_ifb}"
  fi
  clear_ifb "${ifb}"

  if [[ -n "${egress}" ]]; then
    apply_egress "${veth}" "${ifb}" "${egress}"
  fi
  if [[ -n "${ingress}" ]]; then
    apply_ingress "${veth}" "${ingress}"
  fi

  write_state "${sf}" "${container}" "${veth}" "${ifb}" "${egress}" "${ingress}"

  local summary="已对 ${container} (${veth}) 应用带宽限制:"
  if [[ -n "${egress}" ]]; then
    summary+=" 上行 ${egress} Mbps"
  else
    summary+=" 上行 ∞"
  fi
  if [[ -n "${ingress}" ]]; then
    summary+=" 下行 ${ingress} Mbps"
  else
    summary+=" 下行 ∞"
  fi
  echo "${summary}"
}

usage() {
  cat <<EOF
用法:
  $(basename "$0") apply <容器名> [上行Mbps] [下行Mbps]
  $(basename "$0") clear <容器名>

上行 = 容器出网（上传）；下行 = 容器入网（下载）。Mbps 支持 0.1 精度。
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    apply)
      [[ $# -ge 1 ]] || { usage >&2; exit 2; }
      cmd_apply "$1" "${2:-}" "${3:-}"
      ;;
    clear)
      [[ $# -ge 1 ]] || { usage >&2; exit 2; }
      cmd_clear "$1"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
