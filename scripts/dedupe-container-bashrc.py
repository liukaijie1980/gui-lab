#!/usr/bin/env python3
"""Remove exponential .bashrc duplication caused by fix-ssh-shell.sh tail bug."""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SNIPPET = ROOT / "gui_portal" / "kasm-ssh-bashrc.snippet"
INSTANCES_JSON = Path(
    __import__("os").environ.get("GUI_PORTAL_STATE", str(ROOT / "gui_portal" / "instances.json"))
)
MARK_BEGIN = "# BEGIN_GUI_PORTAL_SSH"
MARK_END = "# END_GUI_PORTAL_SSH"
MARKER_LINE = "# --- GUI 容器 SSH 交互环境（由管理台/迁移脚本注入，勿删此标记）---"


def extract_body(lines: list[str]) -> list[str]:
    """Keep content outside the SSH snippet block."""
    body: list[str] = []
    skip = False
    for line in lines:
        if MARK_BEGIN in line:
            skip = True
            continue
        if MARK_END in line:
            skip = False
            continue
        if not skip:
            body.append(line)
    return body


def strip_noise(lines: list[str]) -> list[str]:
    out: list[str] = []
    for line in lines:
        if line.rstrip("\n") == MARKER_LINE:
            continue
        out.append(line)
    return out


def dedupe_halves(lines: list[str]) -> list[str]:
    """Collapse repeated doubling: A+A -> A."""
    cur = lines[:]
    while len(cur) > 1:
        mid = len(cur) // 2
        if cur[:mid] == cur[mid : mid * 2]:
            cur = cur[:mid]
            continue
        break
    return cur


def dedupe_blocks(lines: list[str]) -> list[str]:
    """Collapse repeated adjacent blocks split on generate_container_user."""
    needle = "generate_container_user"
    chunks: list[list[str]] = []
    current: list[str] = []
    for line in lines:
        if needle in line and current:
            chunks.append(current)
            current = [line]
        else:
            current.append(line)
    if current:
        chunks.append(current)

    seen: set[str] = set()
    out: list[str] = []
    for chunk in chunks:
        key = "".join(chunk)
        if key in seen:
            continue
        seen.add(key)
        out.extend(chunk)
    return out


def repair_bashrc(path: Path, dry_run: bool = False) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    before_lines = len(lines)
    before_gen = sum(1 for ln in lines if "generate_container_user" in ln)

    snippet = SNIPPET.read_text(encoding="utf-8")
    if not snippet.endswith("\n"):
        snippet += "\n"

    body = extract_body(lines)
    body = strip_noise(body)
    body = dedupe_halves(body)
    body = dedupe_blocks(body)

    # Trim leading/trailing blank lines in body.
    while body and body[0].strip() == "":
        body.pop(0)
    while body and body[-1].strip() == "":
        body.pop()

    new_text = snippet + ("\n".join(line.rstrip("\n") for line in body) + "\n" if body else "")
    after_lines = new_text.count("\n")
    after_gen = new_text.count("generate_container_user")

    changed = new_text != text
    info = {
        "path": str(path),
        "before_lines": before_lines,
        "after_lines": after_lines,
        "before_gen": before_gen,
        "after_gen": after_gen,
        "changed": changed,
    }

    if changed and not dry_run:
        backup = path.with_suffix(path.suffix + f".bak.{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}")
        shutil.copy2(path, backup)
        path.write_text(new_text, encoding="utf-8")
        info["backup"] = str(backup)

    return info


def home_for_container(name: str) -> Path:
    return ROOT / "docker_os" / name / "home" / ".bashrc"


def list_containers(explicit: list[str]) -> list[str]:
    if explicit:
        return explicit
    data = json.loads(INSTANCES_JSON.read_text(encoding="utf-8"))
    return [i["container_name"] for i in data.get("instances", [])]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("containers", nargs="*", help="container names (default: all instances)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--min-gen", type=int, default=2, help="only repair when generate_container_user count >= N")
    args = parser.parse_args()

    if not SNIPPET.is_file():
        print(f"missing snippet: {SNIPPET}", file=sys.stderr)
        return 1

    names = list_containers(args.containers)
    any_changed = False
    for name in names:
        path = home_for_container(name)
        if not path.is_file():
            print(f"skip {name}: no {path}")
            continue
        gen = sum(1 for ln in path.read_text(encoding="utf-8", errors="replace").splitlines() if "generate_container_user" in ln)
        if gen < args.min_gen:
            print(f"skip {name}: generate_container_user={gen} (< {args.min_gen})")
            continue
        info = repair_bashrc(path, dry_run=args.dry_run)
        flag = "DRY" if args.dry_run else ("FIXED" if info["changed"] else "OK")
        print(
            f"{flag} {name}: lines {info['before_lines']} -> {info['after_lines']}, "
            f"gen_user {info['before_gen']} -> {info['after_gen']}"
        )
        if info.get("backup"):
            print(f"  backup: {info['backup']}")
        any_changed = any_changed or info["changed"]

    return 0 if any_changed or args.dry_run else 0


if __name__ == "__main__":
    raise SystemExit(main())
