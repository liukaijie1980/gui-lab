#!/usr/bin/env bash
# 全面修复 GUI 容器桌面快捷方式：Cursor / VS Code / GitHub Desktop / Claude / 终端等。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTANCES_JSON="${GUI_PORTAL_STATE:-${ROOT}/gui_portal/instances.json}"
TPL_CURSOR="${ROOT}/gui_portal/cursor.desktop.template"
TPL_TERM="${ROOT}/gui_portal/super-terminal.desktop.template"
TPL_GHD="${ROOT}/gui_portal/github-desktop.desktop.template"
TPL_CLAUDE="${ROOT}/gui_portal/claude-code-url-handler.desktop.template"

source "${ROOT}/apps/manifest.env" 2>/dev/null || true
APPIMAGE="${CURSOR_APPIMAGE_NAME:-cursor-latest.AppImage}"

list_containers() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
    return
  fi
  python3 - "${INSTANCES_JSON}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for i in json.load(f).get("instances", []):
        print(i["container_name"])
PY
}

home_for() {
  local cname="$1"
  local h
  h="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/kasm-user"}}{{.Source}}{{end}}{{end}}' "${cname}" 2>/dev/null || true)"
  printf '%s' "${h:-${ROOT}/docker_os/${cname}/home}"
}

install_container_wrappers() {
  local cname="$1"
  "${SCRIPT_DIR}/install-container-app-wrappers.sh" "${cname}"
}

repair_desktop_files() {
  local cname="$1"
  local home="$2"
  python3 - "${cname}" "${home}" "${TPL_CURSOR}" "${TPL_TERM}" "${TPL_GHD}" "${TPL_CLAUDE}" <<'PY'
from __future__ import annotations

import os, re, shutil, subprocess, sys
from pathlib import Path

cname, home, tpl_cursor, tpl_term, tpl_ghd, tpl_claude = sys.argv[1:7]
home_p = Path(home)

REPLACEMENTS = [
    (r"/usr/share/cursor/cursor", "/usr/local/bin/cursor"),
    (r"/usr/share/cursor/bin/cursor", "/usr/local/bin/cursor"),
    (r'"/home/kasm-user/\.nvm/[^"]+/claude\.exe"', "/usr/local/bin/claude"),
    (r'"/home/kasm-user/\.local/bin/claude"', "/usr/local/bin/claude"),
]

def container_path_ok(path: str) -> bool:
    if not path or path.startswith("%"):
        return True
    path = path.strip('"').split()[0]
    if path.startswith("/home/kasm-user"):
        host = home_p / path.replace("/home/kasm-user/", "", 1)
        return host.exists()
    script = f'''
p={path!r}
[[ -x "$p" ]] && exit 0
[[ -f "$p" ]] && exit 0
command -v "$(basename "$p")" >/dev/null 2>&1 && exit 0
exit 1
'''
    try:
        r = subprocess.run(
            ["docker", "exec", cname, "bash", "-lc", script],
            capture_output=True,
            timeout=10,
        )
        return r.returncode == 0
    except Exception:
        return False

def patch_desktop(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    orig = text
    for pat, repl in REPLACEMENTS:
        text = re.sub(pat, repl, text)
    # cursor Exec 补 --no-sandbox
    if "cursor" in path.name.lower() or "/usr/local/bin/cursor" in text:
        text = re.sub(
            r"(Exec=/usr/local/bin/cursor)(?!.*--no-sandbox)",
            r"\1 --no-sandbox",
            text,
        )
    changes = []
    if text != orig:
        path.write_text(text, encoding="utf-8")
        changes.append(f"patched {path.relative_to(home_p)}")
    # validate Exec/TryExec（Icon 仅警告容器内路径）
    for line in text.splitlines():
        if line.startswith(("Exec=", "TryExec=")):
            val = line.split("=", 1)[1].strip().split()[0].strip('"')
            if val.startswith("/") and not container_path_ok(val):
                changes.append(f"WARN missing target {path.name}: {val}")
    return changes

def install_tpl(tpl: str, dest: Path):
    shutil.copy2(tpl, dest)
    dest.chmod(0o755)
    os.chown(dest, 1000, 1000)

desk = home_p / "Desktop"
desk.mkdir(parents=True, exist_ok=True)
apps = home_p / ".local/share/applications"
apps.mkdir(parents=True, exist_ok=True)

log: list[str] = []

# 标准桌面项
install_tpl(tpl_cursor, desk / "cursor.desktop")
install_tpl(tpl_term, desk / "超级终端.desktop")
log.append("cursor.desktop + 超级终端.desktop")

# GitHub Desktop（仅当用户自有 AppImage 启动脚本存在）
ghd_script = home_p / "Apps/github-desktop/run-github-desktop.sh"
if ghd_script.is_file():
    install_tpl(tpl_ghd, desk / "github-desktop.desktop")
    install_tpl(tpl_ghd, apps / "github-desktop.desktop")
    icon = None
    for cand in (
        home_p / "Apps/github-desktop/icons/github-desktop.png",
        home_p / "Apps/github-desktop/github-desktop.png",
    ):
        if cand.is_file():
            icon = cand
            break
    if icon:
        icon_line = "Icon=" + str(icon).replace(str(home_p), "/home/kasm-user", 1)
        for p in (desk / "github-desktop.desktop", apps / "github-desktop.desktop"):
            t = p.read_text(encoding="utf-8", errors="replace")
            t = re.sub(r"^Icon=.*", icon_line, t, flags=re.M)
            p.write_text(t, encoding="utf-8")
    log.append("github-desktop.desktop")
else:
    for p in [desk / "github-desktop.desktop", apps / "github-desktop.desktop"]:
        if p.is_file() and not ghd_script.is_file():
            p.unlink()
            log.append(f"removed broken {p.name}")

# Claude URL handler
install_tpl(tpl_claude, apps / "claude-code-url-handler.desktop")
log.append("claude-code-url-handler.desktop")

# cc-switch：容器无此命令则隐藏
cc = apps / "cc-switch-handler.desktop"
if cc.is_file():
    if not container_path_ok("/usr/bin/cc-switch"):
        t = cc.read_text(encoding="utf-8", errors="replace")
        if "Hidden=true" not in t:
            cc.write_text(t.rstrip() + "\nHidden=true\n", encoding="utf-8")
            log.append("cc-switch-handler Hidden=true")
    else:
        t = cc.read_text(encoding="utf-8", errors="replace")
        t = re.sub(r"\nHidden=true\n?", "\n", t)
        cc.write_text(t, encoding="utf-8")

# 扫描并修补所有 .desktop
for base in [desk, apps, home_p / ".config/xfce4/panel"]:
    if not base.exists():
        continue
    for f in base.rglob("*.desktop"):
        log.extend(patch_desktop(f))

# 清理桌面失效符号链接（保留 Kasm 的 Uploads/Downloads）
for link in desk.iterdir():
    if not link.is_symlink():
        continue
    raw = os.readlink(str(link))
    if link.name in ("Uploads", "Downloads") and raw.startswith("/home/kasm-user/"):
        dest = home_p / raw.replace("/home/kasm-user/", "", 1)
        if not dest.exists():
            dest.mkdir(parents=True, exist_ok=True)
        if not link.is_symlink() or not link.exists():
            pass
        continue
    if "cursor" in raw.lower() or raw.startswith("/usr/share/cursor"):
        link.unlink()
        log.append(f"removed stale cursor symlink {link.name}")
        continue
    target_host = (
        home_p / raw.replace("/home/kasm-user/", "", 1)
        if raw.startswith("/home/kasm-user/")
        else link.parent / raw
    )
    if not target_host.exists():
        link.unlink()
        log.append(f"removed broken symlink {link.name}")

# 安装包/裸 AppImage 移出桌面，避免用户误点
for pattern in ("*.deb", "*.AppImage", "*.appimage"):
    for f in desk.glob(pattern):
        dest = home_p / "Downloads" / f.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists():
            shutil.move(str(f), str(dest))
            log.append(f"moved {f.name} -> Downloads/")

# 恢复 Kasm 桌面常用目录快捷方式（is_symlink：断链时 exists() 为 False 会误重复创建）
for sub, label in (("Uploads", "Uploads"), ("Downloads", "Downloads")):
    dest = home_p / sub
    dest.mkdir(parents=True, exist_ok=True)
    link = desk / label
    target = f"/home/kasm-user/{sub}"
    if link.is_symlink():
        if os.readlink(str(link)) != target:
            link.unlink()
            link.symlink_to(target)
            log.append(f"fixed symlink {label}")
    elif not link.exists():
        link.symlink_to(target)
        log.append(f"restored symlink {label}")

for line in log:
    print(f"  {line}")
PY
}

fix_xfce_helpers() {
  local home="$1"
  local cfg="${home}/.config/xfce4/helpers.rc"
  mkdir -p "$(dirname "${cfg}")"
  if [[ ! -f "${cfg}" ]] || ! grep -q 'TerminalEmulator=xfce4-terminal' "${cfg}" 2>/dev/null; then
    {
      echo 'TerminalEmulator=xfce4-terminal'
      echo 'WebBrowser=google-chrome'
    } >"${cfg}"
    chown 1000:1000 "${cfg}" 2>/dev/null || sudo chown 1000:1000 "${cfg}"
  fi
}

fix_container() {
  local cname="$1"
  local home
  home="$(home_for "${cname}")"
  echo ">>> ${cname} (${home})"
  if docker inspect "${cname}" >/dev/null 2>&1; then
    install_container_wrappers "${cname}"
    echo "  容器: /usr/local/bin/cursor + claude"
  else
    echo "  容器未运行，仅修复家目录内 .desktop" >&2
  fi
  repair_desktop_files "${cname}" "${home}"
  fix_xfce_helpers "${home}"
}

for f in "${TPL_CURSOR}" "${TPL_TERM}" "${TPL_GHD}" "${TPL_CLAUDE}"; do
  [[ -f "${f}" ]] || { echo "缺少模板 ${f}" >&2; exit 1; }
done

mapfile -t NAMES < <(list_containers "$@")
for n in "${NAMES[@]}"; do
  fix_container "${n}"
done
echo "完成。请用户在浏览器桌面刷新或注销后重试各快捷方式。"
