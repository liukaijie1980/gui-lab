"""
Web 管理台：每用户一个 Ubuntu GUI 容器，复用项目根目录的 run-ubuntu22-gui.sh。
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import BackgroundTasks, FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

# 项目根（/data）：含 docker-compose 与启动脚本
ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "run-ubuntu22-gui.sh"
FIX_SSH_SHELL = ROOT / "scripts" / "fix-ssh-shell.sh"
FIX_DESKTOP_SHORTCUTS = ROOT / "scripts" / "fix-desktop-shortcuts.sh"
INSTALL_SSHD_STARTUP = ROOT / "scripts" / "install-sshd-startup.sh"
SYNC_KASM_WEB_PASSWORD = ROOT / "scripts" / "sync-kasm-web-password.sh"
INSTALL_APP_WRAPPERS = ROOT / "scripts" / "install-container-app-wrappers.sh"
CHECK_DISK_SCRIPT = ROOT / "scripts" / "check-instance-disk-usage.sh"
STATE_PATH = Path(os.environ.get("GUI_PORTAL_STATE", ROOT / "gui_portal" / "instances.json"))
SNAPSHOT_DIR = Path(os.environ.get("GUI_PORTAL_SNAPSHOT_DIR", ROOT / "gui_portal" / "snapshots"))
BASE_GUI = int(os.environ.get("GUI_PORTAL_BASE_GUI", "6901"))
PORT_MAX = int(os.environ.get("GUI_PORTAL_PORT_MAX", "6999"))
ADMIN_PASSWORD = os.environ.get("GUI_PORTAL_ADMIN_PASSWORD", "").strip() or None

_SLUG_OK = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
_MEM_RE = re.compile(r"^(\d+)([mg])$", re.IGNORECASE)

_BUILTIN_DEFAULT_RESOURCES: dict[str, Any] = {
    "cpus": os.environ.get("GUI_PORTAL_DEFAULT_CPUS", "2"),
    "memory": os.environ.get("GUI_PORTAL_DEFAULT_MEMORY", "4g"),
    "pids_limit": int(os.environ.get("GUI_PORTAL_DEFAULT_PIDS", "512")),
    "disk_quota_gb": int(os.environ.get("GUI_PORTAL_DEFAULT_DISK_GB", "30")),
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def gui_to_vnc(gui_port: int) -> int:
    """与 README 一致：6901↔5901，端口差 1000。"""
    return gui_port - 1000


def gui_to_ssh(gui_port: int) -> int:
    """与 README 一致：6901↔2201，端口差 4700。"""
    return gui_port - 4700


_BUILTIN_CONTAINER_PORTS = {6901, 5901, 22}


def normalize_extra_ports(raw: Any) -> list[dict[str, Any]]:
    """将 instances.json 中的 extra_ports 规范为 [{host, container, protocol}, ...]。"""
    if not raw:
        return []
    out: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            host = int(item["host"])
            container = int(item["container"])
        except (KeyError, TypeError, ValueError):
            continue
        proto = str(item.get("protocol") or "tcp").lower()
        if proto not in ("tcp", "udp"):
            proto = "tcp"
        out.append({"host": host, "container": container, "protocol": proto})
    return out


def extra_ports_to_env(ports: list[dict[str, Any]]) -> str:
    """传给 run-ubuntu22-gui.sh 的 EXTRA_PORTS：8080:80/tcp,9000:9000/udp。"""
    parts: list[str] = []
    for p in ports:
        proto = p.get("protocol") or "tcp"
        parts.append(f"{p['host']}:{p['container']}/{proto}")
    return ",".join(parts)


def extra_ports_from_docker_inspect(ports: dict[str, Any]) -> list[dict[str, Any]]:
    """从 docker inspect Ports 提取除 Web/VNC/SSH 外的已发布映射。"""
    out: list[dict[str, Any]] = []
    for key, bindings in (ports or {}).items():
        if not bindings:
            continue
        base = key.split("/")[0]
        proto = key.split("/")[1] if "/" in key else "tcp"
        try:
            container = int(base)
        except ValueError:
            continue
        if container in _BUILTIN_CONTAINER_PORTS:
            continue
        for b in bindings:
            hp = b.get("HostPort")
            if hp:
                out.append({"host": int(hp), "container": container, "protocol": proto})
                break
    out.sort(key=lambda x: (x["host"], x["container"]))
    return out


def collect_reserved_host_ports(state: dict[str, Any], *, skip_container: Optional[str] = None) -> set[int]:
    """登记实例占用的宿主机端口（含 GUI/VNC/SSH 与额外映射）。"""
    used: set[int] = set()
    for inst in state.get("instances", []):
        if skip_container and inst.get("container_name") == skip_container:
            continue
        for key in ("gui_port", "vnc_native_port", "ssh_port"):
            v = inst.get(key)
            if v is not None:
                used.add(int(v))
        for p in normalize_extra_ports(inst.get("extra_ports")):
            used.add(int(p["host"]))
    return used


def validate_extra_port_mapping(
    host: int,
    container: int,
    protocol: str,
    state: dict[str, Any],
    *,
    skip_container: Optional[str] = None,
    existing_extra: Optional[list[dict[str, Any]]] = None,
) -> None:
    if host < 1 or host > 65535 or container < 1 or container > 65535:
        raise HTTPException(status_code=400, detail="端口须在 1–65535 之间")
    if host < 1024:
        raise HTTPException(status_code=400, detail="宿主机端口建议使用 1024 及以上（避免占用特权端口）")
    if container in _BUILTIN_CONTAINER_PORTS:
        raise HTTPException(
            status_code=400,
            detail="容器端口 6901/5901/22 已由 Web/VNC/SSH 固定映射，请改 HTTPS/VNC/SSH 端口",
        )
    proto = protocol.lower()
    if proto not in ("tcp", "udp"):
        raise HTTPException(status_code=400, detail="协议须为 tcp 或 udp")
    if port_in_use("0.0.0.0", host):
        reserved = collect_reserved_host_ports(state, skip_container=skip_container)
        if host not in reserved:
            raise HTTPException(status_code=400, detail=f"宿主机端口 {host} 已被占用")
    extra = existing_extra or []
    for p in extra:
        if int(p["host"]) == host:
            raise HTTPException(status_code=400, detail=f"宿主机端口 {host} 已在该实例的额外映射中")
        if int(p["container"]) == container and (p.get("protocol") or "tcp") == proto:
            raise HTTPException(
                status_code=400,
                detail=f"容器端口 {container}/{proto} 已在该实例映射到宿主机 {p['host']}",
            )
    reserved = collect_reserved_host_ports(state, skip_container=skip_container)
    if host in reserved:
        raise HTTPException(status_code=400, detail=f"宿主机端口 {host} 已被其他实例占用")


def default_resources(state: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    """全局默认资源限额（instances.json defaults 优先于环境变量）。"""
    if state:
        raw = (state.get("defaults") or {}).get("resources")
        if raw:
            return normalize_resources(raw, apply_defaults=False)
    return normalize_resources(_BUILTIN_DEFAULT_RESOURCES, apply_defaults=False)


def normalize_resources(raw: Any, *, apply_defaults: bool = True) -> dict[str, Any]:
    """将 resources 规范为 {cpus, memory, pids_limit, disk_quota_gb}，空值表示不限。"""
    base = default_resources() if apply_defaults and not raw else {}
    src = raw if isinstance(raw, dict) else {}
    out: dict[str, Any] = {}

    cpus = src.get("cpus", base.get("cpus"))
    if cpus is not None and str(cpus).strip():
        out["cpus"] = str(cpus).strip()
    else:
        out["cpus"] = None

    mem = src.get("memory", base.get("memory"))
    if mem is not None and str(mem).strip():
        out["memory"] = str(mem).strip().lower()
    else:
        out["memory"] = None

    pids = src.get("pids_limit", base.get("pids_limit"))
    if pids is not None and str(pids).strip() not in ("", "0"):
        try:
            out["pids_limit"] = int(pids)
        except (TypeError, ValueError):
            out["pids_limit"] = None
    else:
        out["pids_limit"] = None

    disk = src.get("disk_quota_gb", base.get("disk_quota_gb"))
    if disk is not None and str(disk).strip() not in ("", "0"):
        try:
            out["disk_quota_gb"] = int(disk)
        except (TypeError, ValueError):
            out["disk_quota_gb"] = 0
    else:
        out["disk_quota_gb"] = 0

    return out


def validate_resources(res: dict[str, Any]) -> None:
    cpus = res.get("cpus")
    if cpus is not None:
        try:
            v = float(cpus)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="CPU 限额须为数字（如 2 或 0.5）")
        if v < 0.1 or v > 128:
            raise HTTPException(status_code=400, detail="CPU 限额须在 0.1–128 之间")

    mem = res.get("memory")
    if mem is not None:
        if not _MEM_RE.match(str(mem)):
            raise HTTPException(status_code=400, detail="内存限额格式无效（如 512m、4g）")
        n, unit = _MEM_RE.match(str(mem)).groups()
        if int(n) < 1:
            raise HTTPException(status_code=400, detail="内存限额须为正整数")

    pids = res.get("pids_limit")
    if pids is not None:
        if not isinstance(pids, int) or pids < 32 or pids > 65535:
            raise HTTPException(status_code=400, detail="进程数限额须在 32–65535 之间")

    disk = res.get("disk_quota_gb", 0)
    if disk is not None and (not isinstance(disk, int) or disk < 0 or disk > 2048):
        raise HTTPException(status_code=400, detail="磁盘配额须在 0（不限）或 1–2048 GB 之间")


def resources_to_env(res: dict[str, Any]) -> dict[str, str]:
    env: dict[str, str] = {}
    if res.get("cpus"):
        env["CPU_LIMIT"] = str(res["cpus"])
    if res.get("memory"):
        env["MEM_LIMIT"] = str(res["memory"])
        env["MEMSWAP_LIMIT"] = str(res["memory"])
    if res.get("pids_limit"):
        env["PIDS_LIMIT"] = str(res["pids_limit"])
    return env


def docker_run_args_for_resources(res: dict[str, Any]) -> list[str]:
    args: list[str] = []
    if res.get("cpus"):
        args += ["--cpus", str(res["cpus"])]
    if res.get("memory"):
        args += ["--memory", str(res["memory"]), "--memory-swap", str(res["memory"])]
    if res.get("pids_limit"):
        args += ["--pids-limit", str(res["pids_limit"])]
    return args


def disk_usage_bytes(container_name: str) -> int:
    total = 0
    for sub in ("home", "persist"):
        d = ROOT / "docker_os" / container_name / sub
        if not d.is_dir():
            continue
        proc = subprocess.run(
            ["du", "-sb", str(d)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        line = (proc.stdout or "").strip().split("\n")[0].strip()
        if line:
            try:
                total += int(line.split()[0])
            except (IndexError, ValueError):
                pass
    return total


def disk_usage_gb(container_name: str) -> float:
    return round(disk_usage_bytes(container_name) / (1024 ** 3), 3)


def disk_status_for_instance(inst: dict[str, Any], *, used_gb: Optional[float] = None) -> dict[str, Any]:
    """按当前 resources.disk_quota_gb 与实时 du 计算磁盘状态（不沿用旧 over_limit）。"""
    res = normalize_resources(inst.get("resources"), apply_defaults=False)
    quota = int(res.get("disk_quota_gb") or 0)
    used = used_gb if used_gb is not None else disk_usage_gb(inst["container_name"])
    over = quota > 0 and used >= quota
    return {
        "used_gb": used,
        "quota_gb": quota,
        "over_limit": over,
        "checked_at": _now_iso(),
    }


def run_disk_check(
    container_name: str,
    disk_quota_gb: int,
    *,
    stop: bool = False,
) -> dict[str, Any]:
    if not CHECK_DISK_SCRIPT.is_file():
        raise HTTPException(status_code=500, detail=f"缺少脚本: {CHECK_DISK_SCRIPT}")
    args = ["/bin/bash", str(CHECK_DISK_SCRIPT), container_name, str(disk_quota_gb)]
    if stop:
        args.append("--stop")
    args.append("--json")
    proc = subprocess.run(args, capture_output=True, text=True, timeout=180)
    if not proc.stdout.strip():
        raise HTTPException(
            status_code=500,
            detail=f"磁盘检查失败: {(proc.stderr or proc.stdout).strip()}",
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise HTTPException(status_code=500, detail=f"磁盘检查输出无效: {proc.stdout[:500]}")


def docker_inspect_resources(name: str) -> Optional[dict[str, Any]]:
    proc = subprocess.run(
        ["docker", "inspect", name],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        return None
    try:
        arr = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if not arr:
        return None
    hc = arr[0].get("HostConfig") or {}
    nano = hc.get("NanoCpus") or 0
    mem = hc.get("Memory") or 0
    pids = hc.get("PidsLimit") or 0
    out: dict[str, Any] = {}
    if nano:
        out["cpus"] = round(nano / 1_000_000_000, 2)
    if mem and mem > 0:
        if mem >= 1024 ** 3:
            out["memory"] = f"{mem // (1024 ** 3)}g"
        else:
            out["memory"] = f"{mem // (1024 ** 2)}m"
    if pids and pids > 0:
        out["pids_limit"] = int(pids)
    return out or None


def ensure_state_defaults(state: dict[str, Any]) -> bool:
    """补全 defaults.resources；为缺 resources 的实例写入默认（不触发重建）。"""
    changed = False
    if "defaults" not in state:
        state["defaults"] = {}
        changed = True
    if "resources" not in state["defaults"]:
        state["defaults"]["resources"] = default_resources()
        changed = True
    defaults = default_resources(state)
    for inst in state.get("instances", []):
        if "resources" not in inst:
            inst["resources"] = dict(defaults)
            changed = True
    return changed


def script_env_for_instance(inst: dict[str, Any]) -> dict[str, str]:
    ssh_p = inst.get("ssh_port") or gui_to_ssh(int(inst["gui_port"]))
    env = {
        "CONTAINER_NAME": inst["container_name"],
        "COMPOSE_PROJECT_NAME": inst["container_name"],
        "GUI_PORT": str(inst["gui_port"]),
        "VNC_NATIVE_PORT": str(inst["vnc_native_port"]),
        "SSH_PORT": str(ssh_p),
        "VNC_PW": inst.get("vnc_pw") or "",
    }
    extra = normalize_extra_ports(inst.get("extra_ports"))
    if extra:
        env["EXTRA_PORTS"] = extra_ports_to_env(extra)
    res = normalize_resources(inst.get("resources"), apply_defaults=False)
    env.update(resources_to_env(res))
    return env


def load_state() -> dict[str, Any]:
    if not STATE_PATH.exists():
        state: dict[str, Any] = {"instances": []}
        ensure_state_defaults(state)
        return state
    with open(STATE_PATH, encoding="utf-8") as f:
        state = json.load(f)
    if ensure_state_defaults(state):
        save_state(state)
    return state


def save_state(data: dict[str, Any]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(STATE_PATH)


def slugify(account: str) -> str:
    s = account.strip().lower().replace("_", "-")
    s = re.sub(r"\s+", "-", s)
    s = re.sub(r"[^a-z0-9-]", "", s)
    s = re.sub(r"-+", "-", s).strip("-")
    return s


def container_name_for(account_slug: str) -> str:
    return f"gui-{account_slug}"


def port_in_use(host: str, port: int) -> bool:
    """检测宿主机 TCP 端口是否已有监听（优先 127.0.0.1，避免 connect 到 0.0.0.0 误判）。"""
    targets = []
    if host in ("0.0.0.0", ""):
        targets = ["127.0.0.1"]
    else:
        targets = [host]
    for addr in targets:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.3)
            try:
                if s.connect_ex((addr, port)) == 0:
                    return True
            except OSError:
                continue
    return False


def collect_used_gui_ports(state: dict[str, Any]) -> set[int]:
    return {int(x["gui_port"]) for x in state.get("instances", [])}


def next_free_gui_port(state: dict[str, Any]) -> int:
    used = collect_used_gui_ports(state)
    for g in range(BASE_GUI, PORT_MAX + 1):
        if g in used:
            continue
        if port_in_use("127.0.0.1", g) or port_in_use("0.0.0.0", g):
            continue
        v = gui_to_vnc(g)
        s = gui_to_ssh(g)
        if port_in_use("127.0.0.1", v) or port_in_use("0.0.0.0", v):
            continue
        if port_in_use("127.0.0.1", s) or port_in_use("0.0.0.0", s):
            continue
        return g
    raise RuntimeError("没有可用端口（请删除旧实例或扩大区间）")


def docker_limits_changed(old: dict[str, Any], new: dict[str, Any]) -> bool:
    """CPU / 内存 / 进程数变更需重建容器；仅磁盘配额变更不需要。"""
    for key in ("cpus", "memory", "pids_limit"):
        if old.get(key) != new.get(key):
            return True
    return False


def run_script(env: dict[str, str], *, recreate: bool = False) -> tuple[int, str, str]:
    if not SCRIPT.is_file():
        raise FileNotFoundError(f"缺少启动脚本: {SCRIPT}")
    e = os.environ.copy()
    # 守护进程无 tty：可由 GUI_PORTAL_SUDO_NONINTERACTIVE=1 让 run-ubuntu22-gui.sh 使用 sudo -n
    if os.environ.get("GUI_PORTAL_SUDO_NONINTERACTIVE", "").strip() in (
        "1",
        "true",
        "yes",
    ):
        e.setdefault("SUDO_NONINTERACTIVE", "1")
    e.update(env)
    if recreate:
        e["RECREATE"] = "1"
    try:
        proc = subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            cwd=str(ROOT),
            env=e,
            capture_output=True,
            text=True,
            timeout=600,
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        err = (exc.stderr or "") if isinstance(exc.stderr, str) else ""
        return 124, out, err or "run-ubuntu22-gui.sh 执行超时（600s）"


def _docker_ok() -> None:
    if not shutil.which("docker"):
        raise HTTPException(status_code=503, detail="未找到 docker 命令，请安装 Docker CLI")


def run_cmd(args: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def _instance_or_404(state: dict[str, Any], container_name: str) -> dict[str, Any]:
    inst = next((x for x in state.get("instances", []) if x["container_name"] == container_name), None)
    if not inst:
        raise HTTPException(status_code=404, detail="未知实例")
    return inst


def docker_inspect_container(name: str) -> Optional[dict[str, Any]]:
    """通过 docker inspect 获取容器摘要（不依赖 docker Python SDK）。"""
    proc = subprocess.run(
        ["docker", "inspect", name],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        return None
    try:
        arr = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if not arr:
        return None
    c = arr[0]
    st = (c.get("State") or {}).get("Status")
    cid = (c.get("Id") or "")[:12]
    ports = (c.get("NetworkSettings") or {}).get("Ports") or {}
    return {"status": st, "id": cid, "ports": ports}


def _is_portal_gui_container_name(name: str) -> bool:
    """与 portal 创建的容器名一致：gui- + 合法 slug（与 container_name_for / 账户校验对齐）。"""
    if not name.startswith("gui-"):
        return False
    slug = name[4:]
    return bool(slug) and bool(_SLUG_OK.match(slug))


def host_ports_from_published(ports: dict[str, Any]) -> tuple[Optional[int], Optional[int], Optional[int]]:
    """从 inspect 的 Ports 解析宿主机 Web(6901)/VNC(5901)/SSH(22) 映射。"""
    def one(container_port: str) -> Optional[int]:
        for key in (f"{container_port}/tcp", f"{container_port}/udp"):
            bindings = ports.get(key)
            if not bindings:
                continue
            hp = bindings[0].get("HostPort")
            if hp:
                return int(hp)
        return None

    return one("6901"), one("5901"), one("22")


def list_portal_container_names() -> list[str]:
    """与 docker ps -a 顺序一致，仅保留本系统命名的 gui-<slug> 容器。"""
    proc = run_cmd(["docker", "ps", "-a", "--format", "{{.Names}}"], timeout=90)
    if proc.returncode != 0:
        raise HTTPException(
            status_code=503,
            detail=(proc.stderr or proc.stdout or "docker ps 失败").strip(),
        )
    out: list[str] = []
    for line in (proc.stdout or "").splitlines():
        primary = line.strip().split(",")[0].strip()
        if _is_portal_gui_container_name(primary):
            out.append(primary)
    return out


def merge_instance_for_display(state_inst: dict[str, Any], docker_row: Optional[dict[str, Any]]) -> dict[str, Any]:
    """登记信息与 docker 对齐：展示端口以当前发布的映射为准。"""
    m = dict(state_inst)
    if docker_row and docker_row.get("ports"):
        gp, vp, sp = host_ports_from_published(docker_row["ports"])
        if gp is not None:
            m["gui_port"] = gp
        if vp is not None:
            m["vnc_native_port"] = vp
        if sp is not None:
            m["ssh_port"] = sp
        m["extra_ports_live"] = extra_ports_from_docker_inspect(docker_row["ports"])
    else:
        m.setdefault("extra_ports_live", [])
    m["extra_ports"] = normalize_extra_ports(m.get("extra_ports"))
    return m


def instance_from_docker_only(name: str, docker_row: Optional[dict[str, Any]]) -> dict[str, Any]:
    """无 instances.json 登记时，仅用容器名 + inspect 构造列表行所需字段。"""
    gp: Optional[int] = None
    vp: Optional[int] = None
    if docker_row and docker_row.get("ports"):
        gp, vp, sp = host_ports_from_published(docker_row["ports"])
    slug = name[4:] if name.startswith("gui-") else ""
    extra_live: list[dict[str, Any]] = []
    if docker_row and docker_row.get("ports"):
        extra_live = extra_ports_from_docker_inspect(docker_row["ports"])
    return {
        "account_label": slug or name,
        "account_slug": slug,
        "container_name": name,
        "gui_port": gp,
        "vnc_native_port": vp,
        "ssh_port": sp,
        "extra_ports": [],
        "extra_ports_live": extra_live,
    }


def ensure_kasm_linux_password(container_name: str, password: str) -> None:
    """同步 kasm-user 的 Linux 密码（SSH 登录用，与 Web 用户名 kasm_user 不同）。"""
    proc = subprocess.run(
        [
            "docker",
            "exec",
            "-u",
            "root",
            "-e",
            "LINUX_PW={}".format(password),
            container_name,
            "bash",
            "-lc",
            'echo "kasm-user:${LINUX_PW}" | chpasswd',
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"设置 kasm-user Linux 密码失败: {(proc.stderr or proc.stdout).strip()}",
        )


def ensure_desktop_shortcuts(container_name: str, *, timeout: int = 180) -> None:
    """修复 Cursor / 超级终端 等桌面快捷方式（指向 /usr/local/bin/cursor）。"""
    if not FIX_DESKTOP_SHORTCUTS.is_file():
        return
    proc = subprocess.run(
        [str(FIX_DESKTOP_SHORTCUTS), container_name],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"修复桌面快捷方式失败: {(proc.stderr or proc.stdout).strip()}",
        )


def ensure_sshd_startup(container_name: str) -> None:
    """确保容器内 sshd 已启动，并写入 custom_startup 以便重启后自启。"""
    if not INSTALL_SSHD_STARTUP.is_file():
        return
    proc = subprocess.run(
        [str(INSTALL_SSHD_STARTUP), container_name],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"启动 sshd 失败: {(proc.stderr or proc.stdout).strip()}",
        )


def ensure_instance_after_recreate(
    container_name: str,
    password: str,
    *,
    strict: bool = True,
    skip_steps: Optional[set[str]] = None,
    shortcuts_timeout: int = 180,
) -> list[str]:
    """容器重建/启动后同步 Web/SSH 密码、shell、桌面快捷方式与 sshd。"""
    warnings: list[str] = []
    skip = skip_steps or set()
    steps = (
        ("Kasm Web 密码", "kasm_pw", lambda: ensure_kasm_user_password(container_name, password)),
        ("Linux 密码", "linux_pw", lambda: ensure_kasm_linux_password(container_name, password)),
        ("SSH shell", "ssh_shell", lambda: ensure_ssh_interactive_shell(container_name)),
        (
            "桌面快捷方式",
            "desktop_shortcuts",
            lambda: ensure_desktop_shortcuts(container_name, timeout=shortcuts_timeout),
        ),
        ("sshd", "sshd", lambda: ensure_sshd_startup(container_name)),
    )
    for label, key, fn in steps:
        if key in skip:
            continue
        try:
            fn()
        except HTTPException as exc:
            if strict:
                raise
            warnings.append(f"{label}: {exc.detail}")
        except subprocess.TimeoutExpired:
            if strict:
                raise
            warnings.append(f"{label}: 执行超时（容器可能仍在启动，可稍后点「启动」重试）")
    return warnings


def install_container_app_wrappers(container_name: str) -> None:
    """安装 /usr/local/bin/cursor（重建后该目录在容器层内，会丢失）。"""
    if not INSTALL_APP_WRAPPERS.is_file():
        return
    subprocess.run(
        ["/bin/bash", str(INSTALL_APP_WRAPPERS), container_name],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=60,
    )


def background_post_recreate(container_name: str, password: str) -> None:
    """资源保存/重建后在后台同步密码与 SSH，并安装 cursor 包装脚本。"""
    install_container_app_wrappers(container_name)
    ensure_instance_after_recreate(
        container_name,
        password,
        strict=False,
        skip_steps={"desktop_shortcuts"},
        shortcuts_timeout=30,
    )


def ensure_ssh_interactive_shell(container_name: str) -> None:
    """SSH 使用 bash + readline，避免 dash 导致方向键无效、提示符异常。"""
    if not FIX_SSH_SHELL.is_file():
        return
    proc = subprocess.run(
        [str(FIX_SSH_SHELL), container_name],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"配置 SSH shell 失败: {(proc.stderr or proc.stdout).strip()}",
        )


def ensure_kasm_user_password(container_name: str, password: str) -> None:
    """
    同步 Kasm Web 密码：kasm_user（官方 Web 用户名）与 kasm-user（SSH 同名，避免填错）。
    """
    if not SYNC_KASM_WEB_PASSWORD.is_file():
        raise HTTPException(status_code=500, detail=f"缺少脚本: {SYNC_KASM_WEB_PASSWORD}")
    proc = subprocess.run(
        ["/bin/bash", str(SYNC_KASM_WEB_PASSWORD), container_name, password],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=180,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"设置 Kasm Web 密码失败: {(proc.stderr or proc.stdout).strip()}",
        )


def _prune_missing_snapshot_files(inst: dict[str, Any]) -> bool:
    """
    若快照对应的 tar 已从磁盘删除，从状态中移除该条记录。
    快照数量按 instances.json 里的 snapshots 数组计算，与目录扫描无关。
    """
    snaps = inst.get("snapshots") or []
    if not snaps:
        return False
    kept: list[dict[str, Any]] = []
    for s in snaps:
        p = s.get("tar_path")
        if p and Path(p).is_file():
            kept.append(s)
    if len(kept) == len(snaps):
        return False
    inst["snapshots"] = kept
    return True


def admin_instance(inst: dict[str, Any]) -> dict[str, Any]:
    """返回给管理台前端的副本（含 SSH 端口与密码，接口已受 check_session 保护）。"""
    x = dict(inst)
    x["login_user"] = "kasm_user"
    x.setdefault("ssh_login_user", "kasm-user")
    gp = x.get("gui_port")
    if gp is not None and x.get("ssh_port") is None:
        try:
            x["ssh_port"] = gui_to_ssh(int(gp))
        except (TypeError, ValueError):
            pass
    # SSH Linux 密码与 VNC_PW 同步
    x["ssh_pw"] = x.get("vnc_pw")
    x["snapshot_count"] = len(x.get("snapshots", []))
    if x.get("snapshots"):
        x["latest_snapshot"] = x["snapshots"][-1]
    x["extra_ports"] = normalize_extra_ports(x.get("extra_ports"))
    if "extra_ports_live" not in x:
        x["extra_ports_live"] = []
    res = normalize_resources(x.get("resources"), apply_defaults=False)
    x["resources"] = res
    x["disk_usage_gb"] = disk_usage_gb(x["container_name"])
    quota = int(res.get("disk_quota_gb") or 0)
    if quota > 0:
        x["disk_over_limit"] = x["disk_usage_gb"] >= quota
    else:
        x["disk_over_limit"] = False
    return x


app = FastAPI(title="GUI 容器管理")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


def check_session(request: Request) -> None:
    if not ADMIN_PASSWORD:
        return
    if request.cookies.get("gui_portal_auth") == ADMIN_PASSWORD:
        return
    raise HTTPException(status_code=401, detail="未登录")


@app.get("/", response_class=HTMLResponse)
def page(request: Request):
    state = load_state()
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "need_login": bool(ADMIN_PASSWORD),
            "logged_in": (not ADMIN_PASSWORD)
            or (request.cookies.get("gui_portal_auth") == ADMIN_PASSWORD),
            "default_resources": default_resources(state),
        },
    )


@app.post("/login")
def login(password: str = Form(...)):
    if not ADMIN_PASSWORD or password != ADMIN_PASSWORD:
        raise HTTPException(status_code=400, detail="密码错误")
    r = RedirectResponse(url="/", status_code=303)
    r.set_cookie("gui_portal_auth", ADMIN_PASSWORD, httponly=True, max_age=86400 * 7)
    return r


@app.post("/logout")
def logout():
    r = RedirectResponse(url="/", status_code=303)
    r.delete_cookie("gui_portal_auth")
    return r


@app.get("/api/instances")
def api_list(request: Request):
    check_session(request)
    state = load_state()
    pruned = False
    for inst in state.get("instances", []):
        if _prune_missing_snapshot_files(inst):
            pruned = True
    if pruned:
        save_state(state)
    _docker_ok()
    by_name = {x["container_name"]: x for x in state.get("instances", [])}
    out = []
    for name in list_portal_container_names():
        row = docker_inspect_container(name)
        st = by_name.get(name)
        if st:
            merged = merge_instance_for_display(st, row)
        else:
            merged = instance_from_docker_only(name, row)
        pub = admin_instance(merged)
        out.append({**pub, "docker": row, "registered": st is not None})
    return {
        "instances": out,
        "script_exists": SCRIPT.is_file(),
        "root": str(ROOT),
        "default_resources": default_resources(state),
    }


@app.post("/api/instances/create")
def api_create(
    request: Request,
    account: str = Form(...),
    password: str = Form(...),
    gui_port: str = Form(default=""),
    res_cpus: str = Form(default=""),
    res_memory: str = Form(default=""),
    res_pids_limit: str = Form(default=""),
    res_disk_quota_gb: str = Form(default=""),
):
    check_session(request)
    if not password.strip():
        raise HTTPException(status_code=400, detail="密码不能为空（将用作 VNC / Web 桌面密码）")
    if len(password.strip()) < 6:
        raise HTTPException(status_code=400, detail="密码至少 6 位（镜像要求）")

    slug = slugify(account)
    if not slug or len(slug) > 40 or not _SLUG_OK.match(slug):
        raise HTTPException(
            status_code=400,
            detail="账户名需为小写字母/数字/连字符，且首尾不能是连字符",
        )

    state = load_state()
    cname = container_name_for(slug)
    for x in state.get("instances", []):
        if x["container_name"] == cname or x.get("account_slug") == slug:
            raise HTTPException(status_code=400, detail="该账户已存在")

    gui: int | None = None
    if gui_port and str(gui_port).strip():
        try:
            gui = int(str(gui_port).strip())
        except ValueError:
            raise HTTPException(status_code=400, detail="GUI 端口必须是整数")
        if gui < 1024 or gui > 65535:
            raise HTTPException(status_code=400, detail="端口范围无效")
        vnc = gui_to_vnc(gui)
        used = collect_used_gui_ports(state)
        if gui in used:
            raise HTTPException(status_code=400, detail="该 GUI 端口已被登记占用")
        if port_in_use("0.0.0.0", gui) or port_in_use("0.0.0.0", vnc):
            raise HTTPException(status_code=400, detail="端口在宿主机上已被占用")
    else:
        gui = next_free_gui_port(state)

    vnc_native = gui_to_vnc(gui)

    raw_res: dict[str, Any] = {}
    if res_cpus.strip():
        raw_res["cpus"] = res_cpus.strip()
    if res_memory.strip():
        raw_res["memory"] = res_memory.strip()
    if res_pids_limit.strip():
        try:
            raw_res["pids_limit"] = int(res_pids_limit.strip())
        except ValueError:
            raise HTTPException(status_code=400, detail="进程数限额须为整数")
    if res_disk_quota_gb.strip():
        try:
            raw_res["disk_quota_gb"] = int(res_disk_quota_gb.strip())
        except ValueError:
            raise HTTPException(status_code=400, detail="磁盘配额须为整数 GB")
    resources = normalize_resources(raw_res if raw_res else None)
    validate_resources(resources)

    env = {
        "CONTAINER_NAME": cname,
        "COMPOSE_PROJECT_NAME": cname,
        "GUI_PORT": str(gui),
        "VNC_NATIVE_PORT": str(vnc_native),
        "SSH_PORT": str(gui_to_ssh(gui)),
        "VNC_PW": password.strip(),
    }
    env.update(resources_to_env(resources))
    code, out, err = run_script(env, recreate=False)
    if code != 0:
        raise HTTPException(
            status_code=500,
            detail=f"启动失败 (exit {code})\n{err or out}",
        )

    ensure_instance_after_recreate(cname, password.strip())

    entry = {
        "account_label": account.strip(),
        "account_slug": slug,
        "login_user": "kasm_user",
        "ssh_login_user": "kasm-user",
        "container_name": cname,
        "gui_port": gui,
        "vnc_native_port": vnc_native,
        "ssh_port": gui_to_ssh(gui),
        "vnc_pw": password.strip(),
        "extra_ports": [],
        "resources": resources,
        "created_at": _now_iso(),
    }
    state.setdefault("instances", []).append(entry)
    save_state(state)
    if resources.get("disk_quota_gb", 0) > 0:
        disk_st = run_disk_check(cname, resources["disk_quota_gb"], stop=False)
        entry["disk_status"] = {
            "used_gb": disk_st.get("used_gb"),
            "quota_gb": disk_st.get("quota_gb"),
            "over_limit": disk_st.get("over_limit"),
            "checked_at": disk_st.get("checked_at"),
        }
        save_state(state)
    return {
        "ok": True,
        "instance": admin_instance(entry),
        "log": (out + err)[-4000:],
    }


@app.get("/api/instances/{container_name}/resources")
def api_get_resources(request: Request, container_name: str):
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    res = normalize_resources(inst.get("resources"), apply_defaults=False)
    live = docker_inspect_resources(container_name)
    used_gb = disk_usage_gb(container_name)
    disk_st = disk_status_for_instance(inst, used_gb=used_gb)
    return {
        "configured": res,
        "live": live,
        "disk_usage_gb": used_gb,
        "disk_status": disk_st,
        "default_resources": default_resources(state),
    }


@app.post("/api/instances/{container_name}/resources")
def api_set_resources(
    request: Request,
    background_tasks: BackgroundTasks,
    container_name: str,
    res_cpus: str = Form(default=""),
    res_memory: str = Form(default=""),
    res_pids_limit: str = Form(default=""),
    res_disk_quota_gb: str = Form(default=""),
):
    """更新资源限额；CPU/内存/进程数变更会重建容器，仅磁盘配额变更则立即保存。"""
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    old_res = normalize_resources(inst.get("resources"), apply_defaults=False)

    raw_res: dict[str, Any] = {}
    raw_res["cpus"] = res_cpus.strip() or None
    raw_res["memory"] = res_memory.strip() or None
    if res_pids_limit.strip():
        try:
            raw_res["pids_limit"] = int(res_pids_limit.strip())
        except ValueError:
            raise HTTPException(status_code=400, detail="进程数限额须为整数")
    else:
        raw_res["pids_limit"] = None
    if res_disk_quota_gb.strip():
        try:
            raw_res["disk_quota_gb"] = int(res_disk_quota_gb.strip())
        except ValueError:
            raise HTTPException(status_code=400, detail="磁盘配额须为整数 GB")
    else:
        raw_res["disk_quota_gb"] = 0

    resources = normalize_resources(raw_res, apply_defaults=False)
    validate_resources(resources)
    needs_recreate = docker_limits_changed(old_res, resources)

    inst["resources"] = resources
    try:
        inst["disk_status"] = disk_status_for_instance(inst)
    except Exception:
        inst["disk_status"] = {
            "used_gb": None,
            "quota_gb": int(resources.get("disk_quota_gb") or 0),
            "over_limit": False,
            "checked_at": _now_iso(),
        }
    save_state(state)

    out, err = "", ""
    recreate_ok = True
    recreate_skipped = not needs_recreate
    post_warnings: list[str] = []

    if needs_recreate:
        env = script_env_for_instance(inst)
        if not env.get("VNC_PW"):
            raise HTTPException(status_code=400, detail="状态中无密码，无法重建")
        code, out, err = run_script(env, recreate=True)
        if code != 0:
            recreate_ok = False
            post_warnings.append(
                "配置已保存，但容器重建失败，请稍后点「重建」使 CPU/内存/进程限制生效。"
                f"\n{(err or out)[-800:]}"
            )
        else:
            background_tasks.add_task(background_post_recreate, container_name, env["VNC_PW"])
            post_warnings.append(
                "容器已重建；密码与 SSH 正在后台同步（约 1 分钟）。"
                "若桌面异常，请点「启动」再次同步。"
            )
    else:
        post_warnings.append("仅更新了磁盘配额，未重建容器。")

    save_state(state)
    live = docker_inspect_resources(container_name)
    resp: dict[str, Any] = {
        "ok": True,
        "saved": True,
        "recreate_ok": recreate_ok,
        "recreate_skipped": recreate_skipped,
        "resources": resources,
        "live": live,
        "log": (out + err)[-4000:] if needs_recreate else "",
    }
    if post_warnings:
        resp["warnings"] = post_warnings
    if needs_recreate and recreate_ok and live and resources.get("cpus") and not live.get("cpus"):
        resp["warnings"] = (resp.get("warnings") or []) + [
            "Docker 未检测到 CPU 限制，请确认容器已成功重建"
        ]
    return resp


@app.post("/api/instances/{container_name}/resources/check-disk")
def api_check_disk(request: Request, container_name: str, stop: bool = Query(default=True)):
    """检查磁盘占用；超限时默认停止容器并更新 disk_status。"""
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    res = normalize_resources(inst.get("resources"), apply_defaults=False)
    quota = int(res.get("disk_quota_gb") or 0)
    if quota <= 0:
        used_b = disk_usage_bytes(container_name)
        return {
            "ok": True,
            "message": "未配置磁盘配额，仅返回当前用量",
            "disk_usage_gb": round(used_b / (1024 ** 3), 3),
            "quota_gb": 0,
            "over_limit": False,
        }
    disk_st = run_disk_check(container_name, quota, stop=stop)
    inst["disk_status"] = {
        "used_gb": disk_st.get("used_gb"),
        "quota_gb": disk_st.get("quota_gb"),
        "over_limit": disk_st.get("over_limit"),
        "checked_at": disk_st.get("checked_at"),
        "stopped": disk_st.get("stopped"),
    }
    save_state(state)
    return {"ok": True, "disk_status": inst["disk_status"]}


@app.post("/api/instances/{container_name}/stop")
def api_stop(request: Request, container_name: str):
    check_session(request)
    state = load_state()
    known = any(x["container_name"] == container_name for x in state.get("instances", []))
    if not known:
        if not _is_portal_gui_container_name(container_name):
            raise HTTPException(status_code=400, detail="非本系统管理的容器名")
        _docker_ok()
        if docker_inspect_container(container_name) is None:
            raise HTTPException(status_code=404, detail="容器不存在")
    else:
        _docker_ok()
    subprocess.run(["docker", "stop", container_name], capture_output=True, text=True, timeout=120)
    return {"ok": True}


@app.post("/api/instances/{container_name}/start")
def api_start(request: Request, container_name: str):
    check_session(request)
    state = load_state()
    known = any(x["container_name"] == container_name for x in state.get("instances", []))
    if not known:
        if not _is_portal_gui_container_name(container_name):
            raise HTTPException(status_code=400, detail="非本系统管理的容器名")
        _docker_ok()
        if docker_inspect_container(container_name) is None:
            raise HTTPException(status_code=404, detail="容器不存在")
    else:
        _docker_ok()
    proc = subprocess.run(
        ["docker", "start", container_name],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=404,
            detail=f"容器不存在或无法启动: {(proc.stderr or proc.stdout).strip()}",
        )
    inst = next((x for x in state.get("instances", []) if x["container_name"] == container_name), None)
    if inst and inst.get("vnc_pw"):
        install_container_app_wrappers(container_name)
        ensure_instance_after_recreate(container_name, inst["vnc_pw"], strict=False)
    return {"ok": True}


@app.post("/api/instances/{container_name}/recreate")
def api_recreate(request: Request, container_name: str):
    """使用登记信息强制重建（应用新端口/密码需先用界面改 state 或删后重建；此处用已存密码）。"""
    check_session(request)
    state = load_state()
    inst = next((x for x in state.get("instances", []) if x["container_name"] == container_name), None)
    if not inst:
        raise HTTPException(status_code=404, detail="未知实例")

    ssh_p = inst.get("ssh_port") or gui_to_ssh(int(inst["gui_port"]))
    env = script_env_for_instance(inst)
    if not env["VNC_PW"]:
        raise HTTPException(status_code=400, detail="状态中无密码，无法重建；请删除后重新创建")
    if len(env["VNC_PW"]) < 6:
        raise HTTPException(status_code=400, detail="状态中的密码少于 6 位，请先更新密码后再重建")

    code, out, err = run_script(env, recreate=True)
    if code != 0:
        raise HTTPException(status_code=500, detail=f"重建失败: {err or out}")
    ensure_instance_after_recreate(container_name, env["VNC_PW"], strict=False)
    inst["ssh_port"] = int(ssh_p)
    inst.setdefault("ssh_login_user", "kasm-user")
    save_state(state)
    return {"ok": True, "log": (out + err)[-4000:]}


@app.post("/api/instances/{container_name}/snapshot/save")
def api_snapshot_save(request: Request, container_name: str):
    """
    保存整容器快照：docker commit + docker save，产出 tar 文件。
    """
    check_session(request)
    _docker_ok()
    state = load_state()
    inst = _instance_or_404(state, container_name)

    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    snap_tag = f"gui-portal-snap:{container_name}-{ts}"
    out_dir = SNAPSHOT_DIR / container_name
    out_dir.mkdir(parents=True, exist_ok=True)
    tar_path = out_dir / f"{container_name}-{ts}.tar"

    c1 = run_cmd(["docker", "commit", container_name, snap_tag], timeout=300)
    if c1.returncode != 0:
        raise HTTPException(status_code=500, detail=f"commit 失败: {(c1.stderr or c1.stdout).strip()}")

    c2 = run_cmd(["docker", "save", "-o", str(tar_path), snap_tag], timeout=1800)
    if c2.returncode != 0:
        raise HTTPException(status_code=500, detail=f"save 失败: {(c2.stderr or c2.stdout).strip()}")

    snap = {
        "created_at": _now_iso(),
        "image_tag": snap_tag,
        "tar_path": str(tar_path),
    }
    inst.setdefault("snapshots", []).append(snap)
    save_state(state)
    return {"ok": True, "snapshot": snap}


@app.post("/api/instances/{container_name}/snapshot/load_latest")
def api_snapshot_load_latest(request: Request, container_name: str):
    """
    从最新快照 tar 恢复容器（删除同名旧容器并按原端口/挂载重建）。
    """
    check_session(request)
    _docker_ok()
    state = load_state()
    inst = _instance_or_404(state, container_name)
    snaps = inst.get("snapshots", [])
    if not snaps:
        raise HTTPException(status_code=400, detail="没有可加载的快照")
    latest = snaps[-1]
    tar_path = Path(latest.get("tar_path", ""))
    if not tar_path.is_file():
        raise HTTPException(status_code=400, detail=f"快照文件不存在: {tar_path}")

    load = run_cmd(["docker", "load", "-i", str(tar_path)], timeout=1800)
    if load.returncode != 0:
        raise HTTPException(status_code=500, detail=f"load 失败: {(load.stderr or load.stdout).strip()}")

    image_tag = latest.get("image_tag")
    if not image_tag:
        raise HTTPException(status_code=400, detail="快照缺少 image_tag")

    # 移除同名旧容器（存在即删）
    run_cmd(["docker", "rm", "-f", container_name], timeout=120)

    home_dir = ROOT / "docker_os" / container_name / "home"
    shared_apps = ROOT / "shared_apps"
    apps_dir = ROOT / "apps"
    home_dir.mkdir(parents=True, exist_ok=True)
    shared_apps.mkdir(parents=True, exist_ok=True)

    run_args = [
        "docker",
        "run",
        "-d",
        "--name",
        container_name,
        "--restart",
        "unless-stopped",
        "--gpus",
        "all",
        "--shm-size",
        "1gb",
        "--add-host",
        "host.docker.internal:host-gateway",
        "-p",
        f"{inst['gui_port']}:6901",
        "-p",
        f"{inst['vnc_native_port']}:5901",
    ]
    ssh_p = inst.get("ssh_port") or gui_to_ssh(int(inst["gui_port"]))
    run_args += ["-p", f"{ssh_p}:22"]
    for ep in normalize_extra_ports(inst.get("extra_ports")):
        proto = ep.get("protocol") or "tcp"
        run_args += ["-p", f"{ep['host']}:{ep['container']}/{proto}"]
    res = normalize_resources(inst.get("resources"), apply_defaults=False)
    run_args += docker_run_args_for_resources(res)
    run_args += [
        "-e",
        "NVIDIA_VISIBLE_DEVICES=all",
        "-e",
        "NVIDIA_DRIVER_CAPABILITIES=all",
        "-e",
        f"VNC_PW={inst.get('vnc_pw', '')}",
        "-v",
        f"{home_dir}:/home/kasm-user",
        "-v",
        f"{shared_apps}:/shared_apps",
    ]
    if apps_dir.exists():
        run_args += ["-v", f"{apps_dir}:/opt/bootstrap/apps:ro"]
    run_args.append(image_tag)

    runp = run_cmd(run_args, timeout=300)
    if runp.returncode != 0:
        raise HTTPException(status_code=500, detail=f"重建失败: {(runp.stderr or runp.stdout).strip()}")

    if inst.get("vnc_pw"):
        ensure_kasm_user_password(container_name, inst["vnc_pw"])
    return {"ok": True, "snapshot": latest}


@app.get("/api/instances/{container_name}/ports")
def api_list_ports(request: Request, container_name: str):
    """返回登记的额外端口与 docker 当前实际映射。"""
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    row = docker_inspect_container(container_name)
    live = extra_ports_from_docker_inspect((row or {}).get("ports") or {}) if row else []
    configured = normalize_extra_ports(inst.get("extra_ports"))
    return {
        "configured": configured,
        "live": live,
        "in_sync": configured == live if row else None,
    }


@app.post("/api/instances/{container_name}/ports")
def api_add_port(
    request: Request,
    container_name: str,
    host_port: int = Form(...),
    container_port: int = Form(...),
    protocol: str = Form(default="tcp"),
):
    """添加一条额外端口映射并重建容器使映射生效。"""
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    extra = normalize_extra_ports(inst.get("extra_ports"))
    validate_extra_port_mapping(
        host_port,
        container_port,
        protocol,
        state,
        skip_container=container_name,
        existing_extra=extra,
    )
    proto = protocol.lower() if protocol else "tcp"
    extra.append({"host": host_port, "container": container_port, "protocol": proto})
    inst["extra_ports"] = extra
    env = script_env_for_instance(inst)
    if not env.get("VNC_PW"):
        raise HTTPException(status_code=400, detail="状态中无密码，无法重建")
    code, out, err = run_script(env, recreate=True)
    if code != 0:
        raise HTTPException(status_code=500, detail=f"应用端口映射失败: {err or out}")
    ensure_instance_after_recreate(container_name, env["VNC_PW"], strict=False)
    save_state(state)
    return {"ok": True, "extra_ports": extra, "log": (out + err)[-4000:]}


@app.delete("/api/instances/{container_name}/ports")
def api_remove_port(
    request: Request,
    container_name: str,
    host_port: int = Query(..., description="要删除的宿主机端口"),
):
    """按宿主机端口删除一条额外映射并重建容器。"""
    check_session(request)
    state = load_state()
    inst = _instance_or_404(state, container_name)
    extra = normalize_extra_ports(inst.get("extra_ports"))
    new_extra = [p for p in extra if int(p["host"]) != host_port]
    if len(new_extra) == len(extra):
        raise HTTPException(status_code=404, detail=f"未找到宿主机端口 {host_port} 的映射")
    inst["extra_ports"] = new_extra
    env = script_env_for_instance(inst)
    if not env.get("VNC_PW"):
        raise HTTPException(status_code=400, detail="状态中无密码，无法重建")
    code, out, err = run_script(env, recreate=True)
    if code != 0:
        raise HTTPException(status_code=500, detail=f"移除端口映射失败: {err or out}")
    ensure_instance_after_recreate(container_name, env["VNC_PW"], strict=False)
    save_state(state)
    return {"ok": True, "extra_ports": new_extra, "log": (out + err)[-4000:]}


@app.delete("/api/instances/{container_name}")
def api_delete(request: Request, container_name: str):
    """从登记中移除并尝试删除容器（数据卷目录不删，便于恢复）。"""
    check_session(request)
    state = load_state()
    inst = next((x for x in state.get("instances", []) if x["container_name"] == container_name), None)
    if not inst:
        if not _is_portal_gui_container_name(container_name):
            raise HTTPException(status_code=400, detail="非本系统管理的容器名")
        _docker_ok()
        if docker_inspect_container(container_name) is None:
            raise HTTPException(status_code=404, detail="未知实例")
    else:
        _docker_ok()
    subprocess.run(
        ["docker", "rm", "-f", container_name],
        capture_output=True,
        text=True,
        timeout=120,
    )

    if inst:
        state["instances"] = [x for x in state["instances"] if x["container_name"] != container_name]
        save_state(state)
    return {"ok": True}


def main() -> None:
    import argparse

    try:
        import uvicorn
    except ImportError:
        print("请先安装依赖: pip install -r gui_portal/requirements.txt", file=sys.stderr)
        sys.exit(1)

    p = argparse.ArgumentParser(description="GUI 容器 Web 管理台")
    p.add_argument("--host", default=os.environ.get("GUI_PORTAL_HOST", "0.0.0.0"))
    p.add_argument("--port", type=int, default=int(os.environ.get("GUI_PORTAL_PORT", "8787")))
    args = p.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, reload=False)


if __name__ == "__main__":
    main()
