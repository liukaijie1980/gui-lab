# GuiLab

**GuiLab**（`gui-lab`）— Ubuntu 22.04 多用户远程图形桌面容器平台。基于 Docker 为每位用户分配独立 GUI 桌面，可选 Web 管理台统一创建与管理实例。

## Ubuntu 22.04 GUI 多容器说明

本目录当前只保留一套方案：现成 Ubuntu 22.04 图形容器；宿主机 **`./shared_apps`** 挂载到每个容器的 **`/shared_apps`**，用于共享文件（应用包、缓存等按需自行放入）。

## 文件说明

- `docker-compose.ubuntu22-gui.yml`：容器定义（基于 Kasm Ubuntu Jammy 的本地自定义镜像）
- `Dockerfile.ubuntu22-gui-nopasswd`：给 `kasm-user` 开启 `sudo NOPASSWD`（`gui + nopasswd` 风格）
- `run-ubuntu22-gui.sh`：生成 `.env.ubuntu22-gui`、拉起容器（**默认不强制重建**已有实例）；**不负责下载**，仅保证 compose 里 **`shared_apps` 挂载**生效
- `gui_portal/`：可选 **Web 管理台**（浏览器里创建/列出/停止/启动/重建实例等），见下文「Web 管理台」
- `gui_portal/gui-portal.service.example`：`systemd` 单元示例，便于把管理台作为系统服务运行
- `apps/manifest.env`、`apps/download-base-apps.sh`、`apps/sync-base-apps.sh`：可选；需要时自行把包放进 `shared_apps` 或手动跑下载/同步脚本

## Web 管理台（可选，`gui_portal/`）

用于在浏览器里管理多实例：填写账户名（映射为容器名 `gui-<账户>`）、**Web/VNC 密码**（即 `VNC_PW`，**至少 6 位**，镜像要求）、可选 HTTPS 端口（不填则自动顺延）；后台调用 **`./run-ubuntu22-gui.sh`** 与 **`docker`** CLI。实例登记保存在 **`gui_portal/instances.json`**（内含各实例密码，请注意文件权限）。

**依赖安装**（在 `/data` 下）：

```bash
pip install -r gui_portal/requirements.txt
```

若与本机其它包冲突，可尝试 `pip install ... --ignore-installed PyYAML`（按报错调整）。

**前台运行**：

```bash
cd /data
export GUI_PORTAL_ADMIN_PASSWORD='你的管理后台密码'   # 可选；不设则无需登录即可打开页面（仅建议在可信网络）
python3 -m gui_portal.app --host 0.0.0.0 --port 8787
```

浏览器访问 `http://<服务器IP>:8787`。常用环境变量：`GUI_PORTAL_HOST`、`GUI_PORTAL_PORT`、`GUI_PORTAL_STATE`（状态文件路径）、`GUI_PORTAL_BASE_GUI` / `GUI_PORTAL_PORT_MAX`（自动分配端口区间）。

**浏览器进入桌面时的登录名**：当前镜像启动脚本固定使用 **`kasm_user`**（与容器 Linux 用户 **`kasm-user`** 不同）；密码为你在管理台创建实例时填写的密码（与 `VNC_PW` 一致）。

**额外端口映射**：在实例列表中点 **「端口映射」**，可图形化添加「宿主机端口 → 容器端口」（例如容器 **80** 映射到宿主机 **8080**）。配置保存在 `instances.json` 的 `extra_ports` 字段，并通过 `run-ubuntu22-gui.sh` 的 **`EXTRA_PORTS`** 写入 `docker_os/<容器名>/extra-ports.compose.yml` 后随 compose 发布。**添加或删除映射会重建该容器**（短暂中断桌面）。Web（6901）、VNC（5901）、SSH（22）仍由创建实例时的 HTTPS/VNC/SSH 端口规则管理，勿在额外映射里重复。

**与 `sudo` 的关系**：管理台进程会以**当前系统用户**执行 `run-ubuntu22-gui.sh`。若该用户为 **UID/GID 1000**（例如本目录常用账号与容器内 `kasm-user` 一致），新建的 `./docker_os/<容器>/home` 一般为 **1000:1000**，**多数情况不会弹出 sudo**。若目录曾被 root 创建、属主不对，脚本仍可能调用 `sudo chown`。守护进程无 tty 时，可在环境里设置 **`GUI_PORTAL_SUDO_NONINTERACTIVE=1`**，使脚本使用 **`sudo -n`**（需事先为该用户配置 **NOPASSWD**，否则会失败退出）；详见 `run-ubuntu22-gui.sh` 内注释。

**作为系统服务**：复制并启用示例单元（路径按需修改）：

```bash
sudo cp /data/gui_portal/gui-portal.service.example /etc/systemd/system/gui-portal.service
sudo systemctl daemon-reload
sudo systemctl enable --now gui-portal.service
```

单元内默认 **`User=lkj`**，请改为实际运行用户；`ExecStart` 中的 `python3` 也可换成虚拟环境解释器路径。

## 前置条件

- 已安装并可用：`docker`、`docker compose`
- 如需走宿主代理，建议在 **`$HOME/proxy.sh`** 中导出 `http_proxy` / `https_proxy`（及大写 `HTTP_PROXY` / `HTTPS_PROXY` 等）。启动脚本若找不到 `$HOME/proxy.sh`，会再尝试 **`/home/lkj/proxy.sh`**（与 `sync-base-apps.sh` 的回退路径一致）。仅写了 `export proxy=...` 时，启动脚本也会尝试用其作为 HTTP 代理来源。

## 方案特点

- Ubuntu 22.04 图形桌面，浏览器访问
- 自动继承宿主机 `http/https/all_proxy`
- 自动把代理中的 `localhost/127.0.0.1` 映射为 `host.docker.internal`
- 每个容器独立 `HOME` 持久化（隔离）
- 所有容器共享同一宿主机目录 **`./shared_apps` → `/shared_apps`**
- 容器内 `kasm-user` 支持 `sudo NOPASSWD`（执行 `sudo` 不再提示输入密码）
- 同名容器再次执行 `run-ubuntu22-gui.sh` 时**默认不重建**，仅 `docker compose up -d` 保证运行中；需让新端口/`VNC_PW`/代理等写入容器环境时，请 **`RECREATE=1`** 再执行；**挂载的家目录与 `shared_apps` 不会丢**

## 快速开始

```bash
cd /data
./run-ubuntu22-gui.sh
```

如需给**宿主机本身**安装 VNC（共享宿主机当前桌面）：

```bash
cd /data
./install-host-vnc.sh
```

脚本安装宿主机 VNC 共享，**自动选择后端**：

| 后端 | 剪贴板 | 中文 |
|------|--------|------|
| **x11vnc**（Ubuntu 22.04 默认） | ✅ 双向可用 | ⚠️ 可能乱码（RFB Latin-1） |
| **TigerVNC x0vncserver ≥1.15**（安装到 `/opt/tigervnc`） | ✅ | ✅ UTF-8 |

> Ubuntu apt 自带的 TigerVNC 1.12 的 `x0vncserver` **没有剪贴板实现**，若强行使用会导致完全无法复制粘贴。脚本会优先尝试从上游安装 1.16，失败则回退 x11vnc。

```bash
cd /data
./install-host-vnc.sh
# 仅 x11vnc：VNC_BACKEND=x11vnc ./install-host-vnc.sh
# 强制重试上游 TigerVNC：INSTALL_TIGERVNC_UTF8=1 ./install-host-vnc.sh
```

若曾装过 x11vnc，安装时会自动停用 `x11vnc.service` 并启用 `host-vnc.service`。

可选环境变量：

- `VNC_PORT`：宿主机 VNC 监听端口（默认 `5900`）
- `VNC_PASSWORD`：非交互设置密码；不传则脚本交互式要求输入

安装完成后可用：

- `vnc://<宿主机IP>:5900`（端口按 `VNC_PORT`）
- `systemctl status host-vnc --no-pager` 查看服务状态

Windows 端请使用 **TigerVNC Viewer 1.12+**（或支持 Extended Clipboard 的客户端）。启动脚本 `scripts/host-vnc-start.sh` 会自动发现当前用户的 X 会话（含 xrdp 的 `:10` 等非 `:0` 显示）。

**浏览器访问宿主机桌面**（类似容器 Kasm Web，剪贴板走 Web/UTF-8 通道）：

```bash
cd /data
./install-host-web-vnc.sh
```

- 访问：`http://<宿主机IP>:6080/vnc.html`（端口可用 `WEB_PORT` 修改）
- 在 noVNC 侧边栏输入 VNC 密码（与 `~/.vnc/passwd` 相同）
- **中文剪贴板**：需 VNC 后端为 **TigerVNC ≥1.15**（`INSTALL_TIGERVNC_UTF8=1 ./install-host-vnc.sh` 安装到 `/opt/tigervnc` 后 `systemctl restart host-vnc host-web-vnc`）；仅 x11vnc 时 Web 里中文仍可能乱码

默认访问（**容器** Kasm 桌面）：

- `https://<服务器IP>:6901`
- `vnc://<服务器IP>:5901`（推荐本机 VNC 客户端，通常比浏览器更流畅）

**浏览器 / WebSocket 登录（易错）**：推荐用户名 **`kasm_user`**（下划线）；**`kasm-user`**（横线，与 SSH 同名）也可，密码均为 **`VNC_PW`**。若 Web 能进桌面但**鼠标键盘无反应**，多半是用了旧版只读权限的 `kasm-user` 账号登录——在管理台对该实例点「启动」触发密码同步，或执行 `scripts/sync-kasm-web-password.sh <容器名> <密码>` 后**断开重连**。也**不要**填容器名（如 `dev-a`）当用户名。

**密码长度**：KasmVNC 要求 **至少 6 位**；过短会导致容器内初始化失败或反复重启。生产环境请使用强密码。

修改 `VNC_PW` 后若未 **`RECREATE=1`** 重建容器，VNC 内仍可能是旧密码（`VNC_PW` 在首次启动时写入 `~/.kasmpasswd`）。

启动脚本会自动做这些事：

- 依次尝试读取 **`$HOME/proxy.sh`**、**`/home/lkj/proxy.sh`**（若存在），把代理 URL 中的 `localhost` / `127.0.0.1` 映射为 **`host.docker.internal`**；若 `no_proxy` 中未包含 `host.docker.internal`，会自动补上
- 生成 **`./.env.ubuntu22-gui`**（供 `docker compose --env-file` 使用；多容器场景下每次启动会覆盖该文件，即「最近一次启动」的快照）
- 自动检查并修正 `HOME_DIR` 对应目录属主为 **`1000:1000`**（Kasm 用户 `kasm-user`）；若当前进程已是 **UID/GID 1000** 且目录为新创建，通常**无需 sudo**。若需 `chown` 且无可交互 tty（如 systemd），可设置环境变量 **`SUDO_NONINTERACTIVE=1`** 使用 **`sudo -n`**，或事先 **`sudo chown -R 1000:1000`** 对应目录，或为运行用户配置 **NOPASSWD**
- 若 Docker 中**已存在同名** `CONTAINER_NAME` 容器：默认执行 `docker compose up -d`（不强制重建）；仅当 **`RECREATE=1`** 时使用 `--force-recreate`

### `run-ubuntu22-gui.sh` 常用环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `CONTAINER_NAME` | `ubuntu22-gui`（或第一个位置参数） | 容器名，建议**一用户一名** |
| `COMPOSE_PROJECT_NAME` | 与 `CONTAINER_NAME` 相同 | `docker compose -p` 项目名，多实例时须与容器一一对应，避免编排状态互相覆盖 |
| `GUI_PORT` | `6901` | 浏览器 HTTPS 入口（映射到容器 `6901`） |
| `VNC_NATIVE_PORT` | `5901` | 原生 VNC 端口（映射到容器 `5901`） |
| `VNC_PW` | `ChangeMe_123` | 桌面 / Web 登录密码（镜像要求 **≥6 位**），生产环境请改为强密码 |
| `SSH_PORT` | `GUI_PORT - 4700`（如 6901→2201） | 宿主机 SSH 映射到容器 22；需镜像含 openssh 且 `RECREATE=1` 后生效 |
| `SUDO_NONINTERACTIVE` | （未设置） | 设为 `1` 时，`sudo` 改为 **`sudo -n`**（守护进程免卡住；需 NOPASSWD 或目录已正确属主） |
| `HOME_DIR` | `./docker_os/<CONTAINER_NAME>/home` | 持久化家目录（相对 `/data`） |
| `RECREATE` | `0` | 设为 `1` 时强制重建容器（应用本次 `.env` 中的端口、密码等） |

## 多容器 / 每用户一容器

设计思路：**每个协作者对应一个容器名 + 独占的宿主机端口 + 自己的 `VNC_PW`**，这样人人有独立桌面与家目录；**所有人仍共用 `./shared_apps`**，适合放安装包、大文件缓存等。Kasm Web 登录用户名始终是 **`kasm_user`**（下划线），只有**密码按容器**不同（即各用户自己的 `VNC_PW`）。

### 端口规划（示例）

为避免冲突，事先为每位用户分配**不重叠**的 `GUI_PORT`（浏览器 HTTPS）与 `VNC_NATIVE_PORT`（原生 VNC）。下表为可直接照抄的一种分配方式（默认单实例占用 `6901` / `5901`，多用户从 `6902` / `5902` 起递增）。

| 用户 / 实例 | `CONTAINER_NAME` | `GUI_PORT`（浏览器） | `VNC_NATIVE_PORT`（VNC 客户端） | `SSH_PORT`（SSH） |
|-------------|-------------------|----------------------|----------------------------------|-------------------|
| 用户 A（如 Alice） | `alice-gui` | `6902` | `5902` | `2202` |
| 用户 B（如 Bob） | `bob-gui` | `6903` | `5903` | `2203` |
| 用户 C（如 Carol） | `carol-gui` | `6904` | `5904` | `2204` |
| 预留 / 默认单实例 | `ubuntu22-gui` | `6901` | `5901` | `2201` |

防火墙或安全组需按实际对外暴露的端口放行（至少每个用户对应的 `GUI_PORT`，若走 VNC 客户端则再加上 `VNC_NATIVE_PORT`，若走 SSH 则再加上 `SSH_PORT`）。

### 多人同时创建：命令行示例

在 **`/data`** 下按用户执行；**`COMPOSE_PROJECT_NAME` 必须与 `CONTAINER_NAME` 一致**（或与你的项目命名规则一一对应），否则不同人的 `docker compose` 状态会互相覆盖。

```bash
cd /data

# 用户 Alice：独占端口与密码，家目录默认为 ./docker_os/alice-gui/home
CONTAINER_NAME=alice-gui COMPOSE_PROJECT_NAME=alice-gui \
  GUI_PORT=6902 VNC_NATIVE_PORT=5902 VNC_PW='Alice_Strong_Secret' \
  ./run-ubuntu22-gui.sh

# 用户 Bob
CONTAINER_NAME=bob-gui COMPOSE_PROJECT_NAME=bob-gui \
  GUI_PORT=6903 VNC_NATIVE_PORT=5903 VNC_PW='Bob_Strong_Secret' \
  ./run-ubuntu22-gui.sh

# 用户 Carol（若仅需两个用户，可省略本条）
CONTAINER_NAME=carol-gui COMPOSE_PROJECT_NAME=carol-gui \
  GUI_PORT=6904 VNC_NATIVE_PORT=5904 VNC_PW='Carol_Strong_Secret' \
  ./run-ubuntu22-gui.sh
```

更短写法：第一个**位置参数**等价于未设置时的 `CONTAINER_NAME`，例如只给容器名时：

```bash
cd /data
GUI_PORT=6902 VNC_NATIVE_PORT=5902 VNC_PW='StrongPassA' ./run-ubuntu22-gui.sh dev-a
# 此时 CONTAINER_NAME 与 COMPOSE_PROJECT_NAME 默认为 dev-a
```

说明：若只传 `dev-a` 未显式设 `COMPOSE_PROJECT_NAME`，脚本里 **`COMPOSE_PROJECT_NAME` 默认等于 `CONTAINER_NAME`**，多用户场景下通常已足够。

### 各人如何访问自己的桌面

以下用「服务器 IP」代指宿主机对客户端可达的地址（内网 IP 或公网 IP，视你的网络而定）。

| 用户 | 浏览器 HTTPS | 原生 VNC 地址 | SSH | Web 用户名 | Web / VNC 密码 |
|------|----------------|---------------|-----|------------|----------------|
| Alice | `https://<服务器IP>:6902` | `vnc://<服务器IP>:5902` 或 `<服务器IP>:5902` | `ssh -p 2202 kasm-user@<服务器IP>` | **`kasm_user`** | 启动时的 `VNC_PW`（示例 `Alice_Strong_Secret`） |
| Bob | `https://<服务器IP>:6903` | `vnc://<服务器IP>:5903` | `ssh -p 2203 kasm-user@<服务器IP>` | **`kasm_user`** | `Bob_Strong_Secret` |
| Carol | `https://<服务器IP>:6904` | `vnc://<服务器IP>:5904` | `ssh -p 2204 kasm-user@<服务器IP>` | **`kasm_user`** | `Carol_Strong_Secret` |

要点：

- **同一服务器上多个桌面时，通过不同端口区分**；不要把别人的端口、密码当成自己的。
- **`CONTAINER_NAME`（如 `alice-gui`）不是登录名**，填进 Kasm 登录框会一直被判为密码错误；登录名必须是 **`kasm_user`**。
- 修改某人 `VNC_PW` 后，要让新密码在容器内生效，需对该用户再执行一次 **`RECREATE=1`** 的同参 `run-ubuntu22-gui.sh`，或按故障排除一节用 **`kasmvncpasswd`** 处理。

### 每人独立数据与共享目录

- **独立**：`HOME_DIR` 默认为 `./docker_os/<CONTAINER_NAME>/home`，不同 `CONTAINER_NAME` 互不覆盖（配置、桌面文件、各自项目）。
- **共享**：所有实例都挂载 **`./shared_apps` → `/shared_apps`**；适合放公共安装包、镜像缓存。需要避免互相覆盖同一文件名时，可在 `/shared_apps` 下按人分子目录（例如 `shared_apps/alice/`、`shared_apps/bob/`），在容器内自行约定即可。

### 启动顺序与 `.env` 快照

每次执行 `run-ubuntu22-gui.sh` 都会**重写** `./.env.ubuntu22-gui`，其内容仅代表**最近一次**启动时那一组 `CONTAINER_NAME` / 端口 / 密码。因此：

- **平时用脚本起停即可**，不必依赖手抄 `.env`。
- 若**手动**执行 `docker compose` 操作**某一用户**的栈，必须使用**该用户当时**的 `COMPOSE_PROJECT_NAME` 加 **`-p`**，并配合**当前磁盘上**的 `./.env.ubuntu22-gui`；更稳妥的做法是：先对该用户再跑一遍同名参数的 **`./run-ubuntu22-gui.sh`**（不重设 `RECREATE` 时仅保证 up，会刷新 `.env` 为该用户），再执行 compose 子命令。

### 可选：每人一条「自己的」启动别名（便于记忆）

在维护者自己的 `~/.bashrc` 中可为固定用户写别名，避免每次敲长环境变量（端口、密码仍须与约定一致）：

```bash
# 示例：仅作快捷方式，请把端口与密码改成你方实际约定
alias gui-alice='cd /data && CONTAINER_NAME=alice-gui COMPOSE_PROJECT_NAME=alice-gui GUI_PORT=6902 VNC_NATIVE_PORT=5902 VNC_PW="Alice_Strong_Secret" ./run-ubuntu22-gui.sh'
alias gui-bob='cd /data && CONTAINER_NAME=bob-gui COMPOSE_PROJECT_NAME=bob-gui GUI_PORT=6903 VNC_NATIVE_PORT=5903 VNC_PW="Bob_Strong_Secret" ./run-ubuntu22-gui.sh'
```

### 多用户下为各容器同步基础应用

若使用 `apps/sync-base-apps.sh`，需要**对每个容器名各执行一次**（与单人相同，只是容器名不同）：

```bash
cd /data
./apps/sync-base-apps.sh alice-gui
./apps/sync-base-apps.sh bob-gui
```

### 简例（与上文 dev-a / dev-b 等价）

```bash
cd /data
CONTAINER_NAME=dev-a COMPOSE_PROJECT_NAME=dev-a GUI_PORT=6902 VNC_NATIVE_PORT=5902 VNC_PW='StrongPassA' ./run-ubuntu22-gui.sh
CONTAINER_NAME=dev-b COMPOSE_PROJECT_NAME=dev-b GUI_PORT=6903 VNC_NATIVE_PORT=5903 VNC_PW='StrongPassB' ./run-ubuntu22-gui.sh
```

小结：

- **`CONTAINER_NAME`（如 `dev-a`）仅用于 Docker 容器名、家目录路径与 compose 项目隔离**，**不是** Kasm Web 登录用户名。
- **每用户独立数据**：`HOME_DIR` 为 `./docker_os/<CONTAINER_NAME>/home`。
- **共享目录**：所有实例挂载同一 **`./shared_apps` → `/shared_apps`**。
- `CONTAINER_NAME` 默认 `ubuntu22-gui`；`COMPOSE_PROJECT_NAME` 默认同 `CONTAINER_NAME`，用于 `docker compose -p` 隔离项目状态。
- 多容器场景下，每次启动都会重写 **`./.env.ubuntu22-gui`**；手动 `docker compose` 时务必 **`-p` 与本次用户一致**，并 **`--env-file ./.env.ubuntu22-gui`**，必要时先对该用户重跑一遍 `run-ubuntu22-gui.sh` 以刷新 `.env`。

## 可选：基础应用脚本（需自行执行）

启动流程**不会**下载或安装软件。若仍希望用脚本辅助，可手动运行（需已存在运行中的容器时见 `sync-base-apps.sh`）：

**`apps/sync-base-apps.sh`** 会处理：

- Google Chrome
- GitHub Desktop（默认使用 `mirror.mwt.me` 的 shiftkey 同步源，避免 `apt.packages.shiftkey.dev` 的 TLS 证书问题；可在 `apps/manifest.env` 中改回官方源）
- Cursor（AppImage）
- Claude Code（npm 全局前缀放到共享目录）

升级流程：

1. 编辑 `apps/manifest.env`
2. 对每个容器执行：

```bash
cd /data
./apps/sync-base-apps.sh <container_name>
```

说明：

- **`shared_apps`（宿主机 `./shared_apps`）**：与 compose 挂载一致；也可把文件直接放进该目录再在容器内使用。**`download-base-apps.sh`**（可选）仅负责把部分包下载到此目录。**`FORCE_REFRESH_DOWNLOADS=1 ./apps/sync-base-apps.sh <容器名>`** 可强制刷新同步脚本内的下载步骤。
- 单独跑同步脚本时，代理读取顺序为：`$HOME/proxy.sh` → `/home/lkj/proxy.sh` → **`./.env.ubuntu22-gui`**；请至少保证其中一处能解析到正确代理（建议在 `proxy.sh` 里写 `http_proxy` / `HTTP_PROXY`）。
- 同步脚本等待容器可 `docker exec` 的最长时间：**`SYNC_WAIT_SECS`**（默认 **`180`**），仅在 **`apps/sync-base-apps.sh`** 内生效。

## SSH 访问（已有容器无损启用）

已为镜像与 compose 增加 **OpenSSH**；用户数据在 **`./docker_os/<容器名>/home`**、**`./shared_apps`**、**`persist`** 卷中，**重建容器不会丢失**（仅短暂中断该实例，约 10–60 秒）。

### 登录说明（与浏览器不同）

| 方式 | 用户名 | 密码 |
|------|--------|------|
| 浏览器 / Kasm Web | **`kasm_user`**（下划线） | `VNC_PW` |
| SSH / Linux shell | **`kasm-user`**（横线） | 迁移脚本默认与 `VNC_PW` 相同；建议登录后 `passwd` 或改用公钥 |

### 为已创建的多个实例批量启用（推荐）

在业务低峰、**逐台**执行（避免同时重建影响所有人）：

```bash
cd /data
# 先构建含 openssh 的镜像（首次执行，去掉 SKIP_BUILD）
SKIP_BUILD=0 ./scripts/enable-ssh-existing.sh

# 仅迁移一台（例如 gui-lkj）
./scripts/enable-ssh-existing.sh gui-lkj

# 预览将执行的操作、不改动容器
DRY_RUN=1 ./scripts/enable-ssh-existing.sh
```

脚本会：按 `gui_portal/instances.json` 中的端口与密码 **`RECREATE=1`** 重建（卷保留）、映射 **`SSH_PORT = GUI_PORT - 4700`**，并把 **`kasm-user` Linux 密码**设为与 `VNC_PW` 相同（可用 `SSH_SYNC_VNC_PW=0` 跳过，改用手动配置 `~/.ssh/authorized_keys`）。

当前登记实例示例（`6901`→`2201`）：

| 容器 | SSH 命令 |
|------|----------|
| gui-lkj | `ssh -p 2201 kasm-user@<服务器IP>` |
| gui-wangyr | `ssh -p 2202 kasm-user@<服务器IP>` |
| gui-caixl | `ssh -p 2203 kasm-user@<服务器IP>` |
| gui-zhangjw | `ssh -p 2204 kasm-user@<服务器IP>` |
| gui-jiann | `ssh -p 2205 kasm-user@<服务器IP>` |

### 手动为单用户启用

```bash
cd /data
docker compose -f docker-compose.ubuntu22-gui.yml build ubuntu22-gui
CONTAINER_NAME=gui-lkj COMPOSE_PROJECT_NAME=gui-lkj \
  GUI_PORT=6901 VNC_NATIVE_PORT=5901 SSH_PORT=2201 VNC_PW='你的密码' \
  RECREATE=1 ./run-ubuntu22-gui.sh
docker exec -u root gui-lkj bash -lc 'echo "kasm-user:你的密码" | chpasswd'
```

通知用户：重建前保存浏览器内未写入家目录的临时文件；重建后桌面与 `~/` 下文件仍在。

### SSH 终端体验（方向键、提示符）

Kasm 默认登录 shell 为 **`/bin/sh`（dash）**，经 SSH 登录时会出现：方向键无法翻历史、提示符显示为 `default:路径$` 等。处理：

```bash
cd /data
./scripts/fix-ssh-shell.sh              # 全部登记实例
./scripts/fix-ssh-shell.sh gui-lkj      # 仅一台
```

脚本会将 **`kasm-user` 默认 shell 改为 bash**，并在持久化家目录注入 SSH 专用 `.bashrc` 片段（检测到 `SSH_CONNECTION` 时使用常规 `user@host:path$` 提示符与 readline）。**无需重建容器**，用户重新 SSH 登录即可。新建实例时管理台会在创建/启动后自动执行同等配置。

### 桌面快捷方式（Cursor / 超级终端）

容器重建后，桌面上的 **Cursor** 若仍指向 `/usr/share/cursor/`（deb 安装路径）会打不开；应改为共享目录 AppImage（`/usr/local/bin/cursor` → `/shared_apps/cursor/cursor-latest.AppImage`）。**超级终端** 为 XFCE 默认终端快捷方式（`xfce4-terminal`）。

```bash
cd /data
./scripts/fix-desktop-shortcuts.sh              # 全部实例
./scripts/fix-desktop-shortcuts.sh gui-wangyr   # 单台
```

会为每台容器安装 `/usr/local/bin/cursor`、`/usr/local/bin/claude`（共享 npm 前缀），并全面扫描修复：

| 类型 | 处理 |
|------|------|
| **Cursor** | `cursor.desktop` → `/usr/local/bin/cursor`（AppImage extract-and-run） |
| **超级终端** | 新建 `超级终端.desktop` → `xfce4-terminal` |
| **GitHub Desktop** | 若存在 `~/Apps/github-desktop/run-github-desktop.sh` 则更新/补全 `.desktop`；否则移除失效项 |
| **Claude Code** | `claude-code-url-handler.desktop` → `/usr/local/bin/claude`（修正错误的 nvm/.local 路径） |
| **VS Code** | `code.desktop` 仍用 `/usr/share/code/code`（镜像内已安装，无需改） |
| **失效符号链接** | 删除指向 `/usr/share/cursor` 的 `cursor` 链接；恢复 `Uploads`/`Downloads` |
| **桌面安装包** | 将 `.deb`/`.AppImage` 移到 `~/Downloads`，避免误点安装 |

其余 Kasm 自带快捷方式（Chrome、Firefox、Telegram、Zoom 等）经验证路径仍有效，未改动。

## 持久化与重建说明

- **`HOME_DIR`**：用户配置、桌面文件、项目等，随宿主机目录持久化。
- **`shared_apps`**：跨容器共享的安装包与缓存；删除前请确认无其他容器仍依赖其中文件。
- **`RECREATE=1`** 或 **`--force-recreate`** 会新建容器实例，**未挂载在卷上的容器内改动会丢失**。`run-ubuntu22-gui.sh`**不会**自动下载或安装应用。
- 若执行 `docker compose ... down` 后再 `up`，挂载数据仍在；需要系统层一键安装时可手动运行 **`./apps/sync-base-apps.sh <容器名>`**。

## 常用命令

停止/启动（**默认** `COMPOSE_PROJECT_NAME=ubuntu22-gui`；多实例请把 **`ubuntu22-gui`** 换成你的项目名，如 **`dev-a`**）：

```bash
cd /data
docker compose -p ubuntu22-gui --env-file ./.env.ubuntu22-gui -f ./docker-compose.ubuntu22-gui.yml stop
docker compose -p ubuntu22-gui --env-file ./.env.ubuntu22-gui -f ./docker-compose.ubuntu22-gui.yml start
```

也可直接按**容器名**起停（不依赖 compose 项目名）：

```bash
docker stop dev-a dev-b
docker start dev-a dev-b
```

仅想**重新跑一遍启动脚本**（不重建设置、刷新 `.env` 并拉起容器）：在 `/data` 下再次执行带相同 `CONTAINER_NAME` 的 **`./run-ubuntu22-gui.sh`**。若要让端口/密码等新 `.env` 写入**容器实例**，请加 **`RECREATE=1`**。

查看 compose 展开结果（**务必加 `-p`**，与创建该容器时一致）：

```bash
cd /data
docker compose -p dev-a --env-file ./.env.ubuntu22-gui -f ./docker-compose.ubuntu22-gui.yml config
```

查看容器内是否带上代理环境变量：

```bash
docker exec <容器名> env | grep -i proxy
```

## 故障排除

### Web 登录密码不对 / 输错几次后无法再连

1. **用户名**：必须是 **`kasm_user`**，密码：**当前容器生效的 `VNC_PW`**（见 `./.env.ubuntu22-gui` 或你启动时的环境变量）。
2. **改了 `VNC_PW` 仍旧密码**：需 **`RECREATE=1`** 后再执行 **`./run-ubuntu22-gui.sh`**，或进容器按 Kasm 文档用 **`kasmvncpasswd`** 重置。
3. **多次错误后「连不上」**：KasmVNC 会把来源 IP 暂时拉黑。可 **`docker restart <容器名>`** 恢复；或等待一段时间再试。启动脚本会在家目录下首次生成 **`~/.config/kasmvnc/kasmvnc.yaml`**（`blacklist_threshold: 0`）以关闭该黑名单；若你已有旧配置未包含此项，可手动合并或删除该文件后重启容器再试。

### 容器内 `http_proxy` / `HTTP_PROXY` 仍是 `localhost` 或 `127.0.0.1`

**原因（已修复）**：`docker compose` 在展开 `docker-compose.*.yml` 里的 `${http_proxy}`、`${HTTP_PROXY}` 时，会**优先采用当前 shell 里已导出的同名变量**。`run-ubuntu22-gui.sh` 在开头会 `source` 你的 `proxy.sh`，其中往往是 `http://localhost:…`，这些值会**盖过** `--env-file` 里已映射好的 `host.docker.internal`，于是新容器环境变量仍是 localhost。

**处理**：请使用已更新的 `run-ubuntu22-gui.sh`（在调用 `docker compose` 前会 `source` 刚生成的 **`./.env.ubuntu22-gui`**，用映射后的代理覆盖 shell）。若需把新 `.env` 写入容器实例，请 **`RECREATE=1 ./run-ubuntu22-gui.sh`**。

若你**不用**启动脚本、自行执行 `docker compose`，请在同一会话里先 `set -a; source ./.env.ubuntu22-gui; set +a`，或先 `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY`，再 `docker compose --env-file ./.env.ubuntu22-gui …`。

**另**：在桌面终端里若持久化家目录中的 **`.bashrc` / `.profile`** 再次 `export http_proxy=http://127.0.0.1:…`，登录 shell 里看到的代理可能又变回 localhost；应改为 **`http://host.docker.internal:端口`**（与 README 中 apt 故障排除一节一致）。

### 容器不断重启，`docker logs` 出现 `Permission denied` 与 `/home/kasm-user`

Kasm 镜像内桌面用户为 `kasm-user`（**UID/GID 1000**）。若 `./docker_os/<名>/home` 在宿主机上是 **root 属主**（常见于路径先由 Docker 自动创建），容器启动时无法向家目录复制默认配置，会进入重启循环。

**处理：** 将对应目录改为 `1000:1000` 后重建容器，例如：

```bash
docker stop dev-a
sudo chown -R 1000:1000 /data/docker_os/dev-a/home
CONTAINER_NAME=dev-a GUI_PORT=6902 VNC_NATIVE_PORT=5902 VNC_PW='StrongPassA' ./run-ubuntu22-gui.sh
```

`run-ubuntu22-gui.sh` 会在 `docker compose up` 前尽量自动创建并修正该目录属主（需本机可用 `sudo`）。

### `docker exec` 报 `Container is restarting`

说明主进程尚未稳定运行。`apps/sync-base-apps.sh` 会等待最多约 180 秒（可用环境变量 `SYNC_WAIT_SECS` 调整）。若一直超时，先按上一节检查 HOME 目录权限，并查看 `docker logs <容器名>`。

### `apt-get` 全部走 `localhost:10811` 且 `Connection refused`

容器里的 `localhost` 不是宿主机。若持久化家目录里的 `.bashrc` / `.profile` 把代理写成 `http://127.0.0.1:10811`，或镜像内 apt 曾指向该地址，`apt` 会连错对象。

`apps/sync-base-apps.sh` 已改为：从宿主机读取代理并映射为 `host.docker.internal`，`docker exec` 使用 `bash --noprofile --norc`，并对 `apt-get` 追加 `Acquire::http::Proxy` 覆盖。

**桌面里长期建议**：在挂载的家目录中把代理改为 `http://host.docker.internal:10811`（端口按你本机代理为准），与容器内一致。

**前提**：宿主机代理需监听 `0.0.0.0:端口`，不能仅绑定 `127.0.0.1`，否则从容器经 `host.docker.internal` 仍连不上。
