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

from fastapi import FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

# 项目根（/data）：含 docker-compose 与启动脚本
ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "run-ubuntu22-gui.sh"
FIX_SSH_SHELL = ROOT / "scripts" / "fix-ssh-shell.sh"
FIX_DESKTOP_SHORTCUTS = ROOT / "scripts" / "fix-desktop-shortcuts.sh"
INSTALL_SSHD_STARTUP = ROOT / "scripts" / "install-sshd-startup.sh"
SYNC_KASM_WEB_PASSWORD = ROOT / "scripts" / "sync-kasm-web-password.sh"
STATE_PATH = Path(os.environ.get("GUI_PORTAL_STATE", ROOT / "gui_portal" / "instances.json"))
SNAPSHOT_DIR = Path(os.environ.get("GUI_PORTAL_SNAPSHOT_DIR", ROOT / "gui_portal" / "snapshots"))
BASE_GUI = int(os.environ.get("GUI_PORTAL_BASE_GUI", "6901"))
PORT_MAX = int(os.environ.get("GUI_PORTAL_PORT_MAX", "6999"))
ADMIN_PASSWORD = os.environ.get("GUI_PORTAL_ADMIN_PASSWORD", "").strip() or None

_SLUG_OK = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


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
    return env


def load_state() -> dict[str, Any]:
    if not STATE_PATH.exists():
        return {"instances": []}
    with open(STATE_PATH, encoding="utf-8") as f:
        return json.load(f)


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
    proc = subprocess.run(
        ["/bin/bash", str(SCRIPT)],
        cwd=str(ROOT),
        env=e,
        capture_output=True,
        text=True,
        timeout=600,
    )
    return proc.returncode, proc.stdout or "", proc.stderr or ""


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


def ensure_desktop_shortcuts(container_name: str) -> None:
    """修复 Cursor / 超级终端 等桌面快捷方式（指向 /usr/local/bin/cursor）。"""
    if not FIX_DESKTOP_SHORTCUTS.is_file():
        return
    proc = subprocess.run(
        [str(FIX_DESKTOP_SHORTCUTS), container_name],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=180,
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


def ensure_instance_after_recreate(container_name: str, password: str) -> None:
    """容器重建/启动后同步 Web/SSH 密码、shell、桌面快捷方式与 sshd。"""
    ensure_kasm_user_password(container_name, password)
    ensure_kasm_linux_password(container_name, password)
    ensure_ssh_interactive_shell(container_name)
    ensure_desktop_shortcuts(container_name)
    ensure_sshd_startup(container_name)


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
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "need_login": bool(ADMIN_PASSWORD),
            "logged_in": (not ADMIN_PASSWORD)
            or (request.cookies.get("gui_portal_auth") == ADMIN_PASSWORD),
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
    return {"instances": out, "script_exists": SCRIPT.is_file(), "root": str(ROOT)}


@app.post("/api/instances/create")
def api_create(
    request: Request,
    account: str = Form(...),
    password: str = Form(...),
    gui_port: str = Form(default=""),
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

    env = {
        "CONTAINER_NAME": cname,
        "COMPOSE_PROJECT_NAME": cname,
        "GUI_PORT": str(gui),
        "VNC_NATIVE_PORT": str(vnc_native),
        "SSH_PORT": str(gui_to_ssh(gui)),
        "VNC_PW": password.strip(),
    }
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
        "created_at": _now_iso(),
    }
    state.setdefault("instances", []).append(entry)
    save_state(state)
    return {
        "ok": True,
        "instance": admin_instance(entry),
        "log": (out + err)[-4000:],
    }


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
        ensure_instance_after_recreate(container_name, inst["vnc_pw"])
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
    ensure_instance_after_recreate(container_name, env["VNC_PW"])
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
    ensure_instance_after_recreate(container_name, env["VNC_PW"])
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
    ensure_instance_after_recreate(container_name, env["VNC_PW"])
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
