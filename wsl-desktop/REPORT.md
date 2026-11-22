# WSL2 嵌套 GNOME 桌面（Ubuntu / Fedora / Kali / Oracle Linux）完整技术报告

> 开源分享版（公开仓库）
> 报告生成：2026-11-12 02:00 前后（CST）
> 适用环境：Windows 10 Pro 26H2（build 26300.9974）+ WSL 3.0.5.0 + WSLg 1.0.79 + Ubuntu 26.04.1 LTS（GNOME Shell 50.1）

---

## 0. 摘要（TL;DR）

1. **原始两个 gist**（完整桌面 Xwayland 方案 / Wayland 嵌套方案）在 Ubuntu 26.04 上，Xwayland 那条已经**结构性不可行**（GNOME 50 移除了 X11 会话与 GDM 的 X11 支持）；Wayland 那条可以用社区配方改造后运行。
2. 本机最终方案：**Ubuntu 26.04 + GNOME 50 的 mutter devkit 嵌套会话**，通过 WSLg 的 `mutter-devkit` 窗口显示桌面；`gnome-session` 由 systemd 用户单元托管，关掉终端也不会退出。
3. 在这个嵌套会话里补齐了两个 WSLg 的短板：
   - **剪贴板**：Linux → Windows 方向 WSLg 原生可用；Windows → Linux 方向由自研 `clipbridge`（+ systemd 用户服务）补齐，**仅文本**，双向实测通过。
   - **声音**：两个独立根因：
     - WSLg 的 PulseAudio 服务会周期性**卡死**（listen 队列堆积、不再 accept），表现为「设置 > 声音」里无输出设备、所有应用失声；
     - **snap 版 Firefox/Thunderbird** 的 `PULSE_SERVER` 被 snapd 固定到会话里的 `pipewire-pulse` 哑设备（`虚拟输出`），导致「闹铃有声音、浏览器没声音」。
   - 修复：环境变量 + 屏蔽 `pipewire-pulse` + **把 WSLg 的 `PulseServer` bind mount 到 `/run/user/1000/pulse/native`**（系统级常驻服务，自动处理 PulseAudio 重启后的重绑定）+ 关闭系统提示音；另提供 `fix-audio.ps1`（重启 WSL 复位）与 `audio-watchdog.ps1`（热重启 PulseAudio 的看门狗）。
4. 全部脚本/文档已提交到私有仓库，之后每次改动都会 `commit + push`。

---

## 1. 目标与背景

### 1.1 原始需求

最初要求分析并复现两个 Gist：

- **Xwayland 版**：<https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912>
  「Full desktop shell in WSL2 using WSLg (XWayland)」——核心是让 `gnome-session` 跑 **X11 会话**、GDM 启动桌面，用 Xwayland 冒充 Xorg。
- **Wayland 版**：<https://gist.github.com/tdcosta100/7def60bccc8ae32cf9cacb41064b1c0f>
  「Nested GNOME desktop via Wayland」——mutter devkit 嵌套会话。

### 1.2 为什么 Ubuntu 26.04 上 Xwayland 路线不可行

- Ubuntu 26.04 = **GNOME 50**，GNOME 50 **移除了 X11 会话**，GDM 也**移除了 X11 支持**；
- 原教程依赖「用 Xwayland 冒充 `/usr/bin/Xorg` + GDM 拉起 X11 会话」，这两个前提在 26.04 都不存在；
- gist 评论区 2026-07 已有人确认 **“It doesn't work with 26.04”**，之后没有新的成功方案。

**结论**：26.04 上要么用嵌套 Wayland 方案（本报告），要么另装 Ubuntu 24.04 跑原 Xwayland 教程（仓库里保留 `wsl-desktop-2404-xwayland.sh` 自动化脚本）。

### 1.3 最终选型

| 路线 | 发行版 | 效果 | 本质 |
|---|---|---|---|
| A（本机采用） | Ubuntu 26.04 | 一个 GNOME 桌面窗口（mutter devkit），无登录界面；可加 RDP | 嵌套 GNOME 会话 + WSLg 显示 |
| B（保留脚本） | 仅 Ubuntu 24.04 | 带 GDM 登录界面的完整桌面 | 替换 Xorg + Xwayland + GDM |

---

## 2. 测试环境（实测采集，2026-11-12 01:55）

### 2.1 Windows 侧

| 项 | 值 |
|---|---|
| 产品 | Windows 10 Pro 26H2 |
| 版本 | 10.0.26300.9974 |
| WSL | 3.0.5.0（内核 6.18.58.1-1） |
| WSLg | 1.0.79（Build 2026-06-25，基于 Microsoft Azure Linux 3.0） |
| MSRDC | 1.2.7391 |
| Direct3D | 1.611.1-81528511 |
| 音频设备 | 扬声器（High Definition Audio Device）、阵列麦克风（AMD Audio Device），AudioSrv 运行中 |

### 2.2 WSL 配置

`/etc/wsl.conf`（Ubuntu 发行版内）：

```ini
[boot]
systemd=true

[user]
default=u
```

`C:\Users\<用户名>\.wslconfig`（Windows 侧，关键项）：

```ini
[general]
instanceIdleTimeout=-1

[wsl2]
vmIdleTimeout=-1
guiApplications=true        ; 必须为 true，否则 WSLg 不工作
nestedVirtualization=false
networkingMode=mirrored
autoProxy=true
```

> 排障史：早期这里写成 `guiApplications=false`，导致 `DISPLAY` 不存在、`/mnt/wslg` 全空，桌面窗口怎么都出不来。改成 `true` 并 `wsl --shutdown` 后解决。

### 2.3 Ubuntu 内部

| 项 | 值 |
|---|---|
| 发行版 | Ubuntu 26.04.1 LTS（Resolute Raccoon） |
| 用户 / 主机 | `<用户名>@<主机名>` |
| 内核 | 6.18.58.1-microsoft-standard-WSL2 |
| GNOME Shell | 50.1（`gnome-shell 50.1-0ubuntu1.5`） |
| mutter-dev-bin | 50.1-0ubuntu2.5 |
| gnome-control-center | 1:50.3-0ubuntu0.2 |
| PipeWire | 1.6.2（pipewire / pipewire-pulse / pipewire-audio / wireplumber 0.5.13） |
| libpulse0 / pulseaudio-utils | 1:17.0+dfsg1-2ubuntu4 |
| Firefox | snap 159.0.1-1（rev 9171） |
| Thunderbird | snap 159.0-1（rev 1312） |
| 显示 | WSLg：`DISPLAY=:0`、`WAYLAND_DISPLAY=wayland-0`；嵌套会话自己的 Wayland socket：`/run/user/1000/wayland-0`（由 gnome-shell 监听） |

---

## 3. 桌面搭建（当前生效配置）

### 3.1 安装组件

```bash
sudo apt-get update
sudo apt-get install -y ubuntu-desktop          # 默认 --no-install-recommends 也可
sudo apt-get install -y mutter-dev-bin          # 提供 /usr/libexec/mutter-devkit
```

### 3.2 关键：gnome-shell 用户服务 override

文件：`/etc/systemd/user/org.gnome.Shell@.service.d/override.conf`

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --devkit --no-x11 --mode=%i
Environment=GDK_BACKEND=x11
Environment=DISPLAY=:0
Environment=PULSE_SERVER=unix:/mnt/wslg/PulseServer
```

- `--devkit`：让 mutter 以 headless/devkit 方式运行，由 `mutter-devkit`（GTK 查看器）把画面显示成一个普通 WSLg 窗口；
- `GDK_BACKEND=x11` + `DISPLAY=:0`：**必须**。否则 `mutter-devkit` 会去连嵌套 shell 自己的 `wayland-0`，窗口永远不出现（这是第一次调试时卡住最久的坑）；
- `PULSE_SERVER`：让 shell 及其子进程能连 WSLg 音频（详见第 5 章）。

### 3.3 启动脚本 `~/start-desktop.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
export PULSE_SERVER="${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY PULSE_SERVER 2>/dev/null || true
systemctl --user set-environment DISPLAY=:0 PULSE_SERVER="$PULSE_SERVER" 2>/dev/null || true
systemctl --user start wsl-clipbridge 2>/dev/null || true
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
gsettings set org.gnome.desktop.sound event-sounds false 2>/dev/null || true
gsettings set org.gnome.desktop.sound input-feedback-sounds false 2>/dev/null || true
extra=()
[ -n "${GALLIUM_DRIVER:-}" ] && extra+=("GALLIUM_DRIVER=$GALLIUM_DRIVER")
exec env XDG_CURRENT_DESKTOP=ubuntu:GNOME XDG_SESSION_TYPE=wayland "${extra[@]}" gnome-session "$@"
```

### 3.4 会话托管（关掉终端也不会退出）

用 systemd 用户单元托管（repo 里 `audio/restart-desktop.sh`）：

```bash
systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh
```

- `systemd-run --user` 让 `gnome-session` 跑在独立 transient 单元里，**关掉终端不会退出**；
- 桌面窗口标题为 **Mutter Development Kit**：关掉窗口 = 关掉桌面（mutter-devkit 断开后 gnome-shell 会退出，日志里能看到 `Client error: socket disconnected` → `Shutting down GNOME Shell`）；
- 重开桌面：`systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh`（或 `audio/restart-desktop.sh`）。

### 3.5 搭建阶段排障记录

| 现象 | 根因 | 处理 |
|---|---|---|
| 桌面窗口一直不出现 | `.wslconfig` 里 `guiApplications=false`，WSLg 被禁用（无 `DISPLAY`、`/mnt/wslg` 空） | 改 `true` + `wsl --shutdown` |
| 桌面窗口仍不出现 | `mutter-devkit` 连到嵌套 shell 自己的 Wayland socket | shell override 里加 `GDK_BACKEND=x11`、`DISPLAY=:0`，并 `systemctl --user import-environment` |
| 关掉终端桌面就没了 | `gnome-session` 是终端子进程 | 改用 `systemd-run --user` 托管 |
| 桌面里没有声音设备 | WSLg PulseAudio 卡死 / 会话里 pipewire 哑设备 | 见第 5 章 |
| `tail -20 /tmp/...` 报错 `option used in invalid context -- 2` | Ubuntu 26.04 的 `tail` 是 **uutils coreutils 0.10**（Rust 版），老式 `-20` 与路径连写（`-20/tmp/...`）会报错 | 统一用 `tail -n 20 文件` |

---

## 4. 剪贴板双向同步

### 4.1 实测结论（与用户现象完全对上）

用户最初反馈「**能复制，不能粘贴**」。实测：

| 方向 | 是否原生 | 说明 |
|---|---|---|
| Linux（嵌套桌面）复制 → Windows 粘贴 | ✅ 原生 | WSLg 自带跨系统剪贴板同步，立即生效 |
| Windows 复制 → Linux 嵌套桌面粘贴 | ❌ 原生不通 | 由 `clipbridge` 补上，延迟约 0.5~2 秒 |

之所以「复制能用」：从嵌套会话复制时，WSLg 会把它同步到 Windows 剪贴板；而 Windows → 嵌套会话方向没有对应通道。

### 4.2 架构

```
[嵌套 GNOME 会话]                     [WSLg 外层]                [Windows]
应用 Wayland 剪贴板  ──clipbridge──▶  X11 剪贴板 (DISPLAY=:0) ──原生──▶ Windows 剪贴板
       ▲                                                             │
       └─────────────── 原生（WSLg 负责） ◀──────────────────────────┘
```

`clipbridge` 只做「Windows → 会话」这一半：轮询 WSLg 外层 X11 剪贴板（`xclip -o`），内容变化就 `wl-copy` 进嵌套会话的 Wayland 剪贴板。

### 4.3 clipbridge 实现（`/usr/local/bin/clipbridge`）

要点：

- 只同步**纯文本**（`wl-paste -n -t text`），跳过空内容；
- `flock` 单实例锁（`/tmp/clipbridge.lock`），避免早期「同时跑 3 个实例」的问题；
- 内层 Wayland socket 未就绪时自动等待（`[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]`）；
- 日志 `/tmp/clipbridge.log`（超过 200 行自动裁剪，只记录方向与字符数，不记录内容）。

### 4.4 systemd 用户服务

`~/.config/systemd/user/wsl-clipbridge.service`：

```ini
[Unit]
Description=WSL 剪贴板三层桥（内层 Wayland ⇄ WSLg X11 ⇄ Windows）
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/usr/local/bin/clipbridge
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
```

已 `enable`，`~/start-desktop.sh` 里也会 `systemctl --user start wsl-clipbridge`（双保险）。

### 4.5 排障记录

| 现象 | 原因 | 处理 |
|---|---|---|
| 终端里 `tail -20 /tmp/clipbridge.log` 报错 | uutils coreutils 的 `-20` 语法坑 | 用 `tail -n 20` |
| 同时存在多个 clipbridge 进程 | 手动启动 + autostart 重复 | `flock` 单实例 + 删除 `~/.config/autostart/clipbridge.desktop`，改 systemd 服务 |
| `/tmp/clipbridge.log` 空 | 早期版本没写日志 | 新版本按「方向 + 字符数」记录 |
| 测试时剪贴板偶发被旧值覆盖 | 桥接轮询与原生同步的时序竞争 | 比较 `wl`/`x` 后再写，空值跳过；单向化（只做 Windows→内层）后稳定 |

### 4.6 验证

`clipboard/final-clip-test.sh` 自测（会临时覆盖剪贴板，最后还原）：

```
== 1. Linux 复制 -> Windows 粘贴（WSLg 原生）== OK
== 2. Windows 复制 -> Linux 粘贴（clipbridge）== OK（约 1 秒）
== 3. 中文双向 == OK / OK
== 4. 服务资源占用 == CPU 0.1%
```

---

## 5. 音频（本次重点，问题最深）

### 5.1 现象

1. 用户截图：「设置 > 声音」里 **输出设备：无输出设备 / 输入设备：无输入设备**；
2. 后来演变为组合现象：**闹铃（终端里 `paplay`）有声音，但浏览器（Firefox）没有声**。

### 5.2 WSLg 音频架构

```
Linux 应用 ──PulseAudio 协议──▶ [WSLg 系统发行版] pulseaudio
                                   ├─ module-rdp-sink   （RDPSink）
                                   └─ module-rdp-source （RDPSource）
                                        │  通过 unix socket
                                        ▼
                                   Weston（rdp-backend.so）
                                        │  RDP 音频通道（rdpsnd）
                                        ▼
                                   msrdc.exe（Windows 侧 WSLg 客户端）
                                        ▼
                                   Windows 默认音频设备
```

WSLg 系统发行版里启动命令（可从 `wsl --system` 看到）：

```
/usr/bin/pulseaudio --log-time=true --disallow-exit=true --exit-idle-time=-1 \
  --load=module-rdp-sink sink_name=RDPSink \
  --load=module-rdp-source source_name=RDPSource \
  --load=module-native-protocol-unix socket=/mnt/wslg/PulseServer auth-anonymous=true \
  --log-target=newfile:/mnt/wslg/pulseaudio.log
```

### 5.3 诊断工具箱（本次用到的）

| 工具/命令 | 用途 |
|---|---|
| `pactl -s unix:/mnt/wslg/PulseServer info` | 直连 WSLg PulseAudio，判断是否卡死 |
| `pactl list short sinks/sources/clients/sink-inputs` | 设备、客户端、播放流 |
| `ss -xl` | 看 `/mnt/wslg/PulseServer` 的 LISTEN 队列（Recv-Q/Send-Q） |
| `python3` 原始 socket 连接测试 | 区分「连不上」还是「连上没响应」 |
| `ps -eo pid,ppid,user,stat,cmd` / `/proc/<pid>/task/*/wchan` | 看 PulseAudio 线程阻塞在哪 |
| `/mnt/wslg/pulseaudio.log`、`/mnt/wslg/weston.log` | WSLg 音频/Weston 日志 |
| `wsl.exe --system -- ...` | **进入 WSLg 系统发行版**（可看到并操作它的 pulseaudio/weston 进程） |
| `wpctl status`、`pactl -s unix:/run/user/1000/pulse/native` | 会话内 PipeWire / pipewire-pulse |
| `audio/audio-watch.sh` | 每 5 秒记录音频健康状态到 `/tmp/audio-watch.log` |

### 5.4 根因 1：WSLg 的 PulseAudio 会卡死

**证据链**（多次复现）：

1. 应用侧：`pactl` 报 `连接失败：拒绝连接` / `Connection refused`；`paplay` 超时（rc=124）。
2. socket 侧：`ss -xl` 显示

   ```
   u_str LISTEN 6 5 /mnt/wslg/PulseServer ...
   u_str LISTEN 3 5 /mnt/wslg/runtime-dir/pulse/native ...
   ```

   Recv-Q 持续增长并超过 backlog，说明 **daemon 不再 accept 新连接**；Python 非阻塞 `connect()` 直接 `BlockingIOError [Errno 11] (EAGAIN)`。
3. 系统发行版里看：`pulseaudio` 进程还在（mainloop 在 futex 等待，rdp-sink/rdp-source 线程在 read/poll），说明不是崩溃，而是**主循环被卡住**。
4. `pulseaudio.log` 出现大量

   ```
   W: [rdp-sink] asyncq.c: q overrun, queuing locally
   ```

5. `weston.log` 出现

   ```
   Audio sink thread: error while reading from sink socket sizeRead:0. Success
   ```

   即 Weston 的音频消费端读到 EOF/异常，RDP 音频通道停摆 → PulseAudio 的 rdp-sink 侧积压 → 整个 daemon 冻结。

**触发条件（观察到的）**：

- 播放一段声音（系统提示音、`paplay`、浏览器视频）之后，可能几十秒~几分钟内卡死；
- 打开「设置 > 声音」面板时也曾两次立刻触发（面板里 gvc 的连接动作），不过后来同一面板又能正常显示 RDPSink，说明存在启动时序/状态依赖；
- WSL 启动后**偶尔**一开始就是坏的（boot race），所以「重启 WSL 后先测试」并不总是稳定。

**为什么不能只 `kill` PulseAudio（早期结论，后修正）**：

早期直接 `kill -9` 后，虽然 WSLGd 会自动拉起新的 PulseAudio（socket 也会重建），但当时出现过 Weston 音频线程已 EOF、播放路径不恢复的情况，因此当时建议「只能整体重启 WSL」。

**后修正（2026-11-12 01:56 实测）**：在**加入自动重绑定逻辑后**，热重启 PulseAudio 可以恢复：

```powershell
wsl --system -- sh -c "pkill -9 pulseaudio"
```

- WSLGd 自动拉起新的 pulseaudio（新 socket）；
- `wslg-pulse-bind` 守护发现 `PulseServer` inode 变化 → 自动重新 bind mount；
- 之后 `pactl` 正常、`paplay` rc=0、15 秒观察稳定 → **可作为看门狗的恢复手段**（见 5.7）。

### 5.5 根因 2：snap 应用的音频被路由到 pipewire 哑设备

用户现象「闹铃有声、浏览器无声」的直接原因：

- snapd 会把 snap 应用的 `PULSE_SERVER` 强制设置成 `unix:$XDG_RUNTIME_DIR/pulse/native`（Firefox 里实际值：`unix:/run/user/1000/snap.firefox/../pulse/native` → 归一化为 `/run/user/1000/pulse/native`）；
- 而会话里的 `/run/user/1000/pulse/native` 属于 **pipewire-pulse**（GNOME 会话自带），它没有任何真实声卡，只有 `auto_null`（界面显示「虚拟输出」）；
- 于是 Firefox 的音频流进了 pipewire，pipewire 只有哑 sink → 没声音；而终端里的 `paplay` 用的是环境变量 `PULSE_SERVER=unix:/mnt/wslg/PulseServer`，所以闹铃有声。

证据：

- Firefox 进程环境：

  ```
  PULSE_SERVER=unix:/run/user/1000/snap.firefox/../pulse/native
  XDG_RUNTIME_DIR=/run/user/1000/snap.firefox
  ```

- `wpctl status` / `pactl -s unix:/run/user/1000/pulse/native list short sink-inputs`：

  ```
  78  53  52  PipeWire  float32le 2ch 48000Hz     # Firefox 的流
  Sinks: * 53. 虚拟输出
  Streams: 63. Firefox  output_FR > 虚拟输出:playback_FR
                          output_FL > 虚拟输出:playback_FL
  ```

### 5.6 解决方案（当前生效）

#### 5.6.1 会话环境变量（让 GNOME/终端应用用 WSLg 音频）

1. shell override 加 `Environment=PULSE_SERVER=unix:/mnt/wslg/PulseServer`；
2. `~/.config/environment.d/pulse.conf`：

   ```
   PULSE_SERVER=unix:/mnt/wslg/PulseServer
   ```

3. `~/start-desktop.sh` 里 `export PULSE_SERVER` + `systemctl --user set-environment`；
4. 关闭系统提示音/启动音（避免播放提示音后卡死）：

   ```bash
   gsettings set org.gnome.desktop.sound event-sounds false
   gsettings set org.gnome.desktop.sound input-feedback-sounds false
   ```

#### 5.6.2 屏蔽 pipewire-pulse（把会话 pulse socket 让出来）

```bash
systemctl --user stop pipewire-pulse.socket pipewire-pulse.service
systemctl --user mask pipewire-pulse.socket pipewire-pulse.service
```

#### 5.6.3 关键：bind mount WSLg 的 PulseAudio socket 到会话路径

系统服务 `/etc/systemd/system/wslg-pulse-bind.service`：

```ini
[Unit]
Description=Bind-mount WSLg PulseServer into session PulseAudio socket
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wslg-pulse-bind
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`/usr/local/bin/wslg-pulse-bind`（常驻守护，3 秒一轮）：

```bash
#!/usr/bin/env bash
set -u
TARGET=/run/user/1000/pulse/native
SOURCE=/mnt/wslg/PulseServer
ensure() {
  [ -S "$SOURCE" ] || return 0
  [ -S /run/user/1000/bus ] || return 0
  mkdir -p /run/user/1000/pulse
  if mountpoint -q "$TARGET" 2>/dev/null; then
    if [ "$TARGET" -ef "$SOURCE" ]; then
      return 0
    fi
    umount "$TARGET" 2>/dev/null || true
  fi
  rm -f "$TARGET"
  touch "$TARGET"
  chown u:u "$TARGET"
  mount --bind "$SOURCE" "$TARGET" 2>/dev/null || true
}
while :; do
  ensure
  sleep 3
done
```

效果：snap 应用连接 `/run/user/1000/pulse/native` → 内核直接把它递到**真实的 WSLg PulseServer socket**（完整协议、支持 shm），Firefox 的声音就进了 WSLg → Windows 扬声器。

**验证（2026-11-12 01:57）**：

```
$ pactl -s unix:/run/user/1000/pulse/native info
Server Name: pulseaudio
Default Sink: RDPSink
$ paplay --server=unix:/run/user/1000/pulse/native complete.oga   # rc=0（有声音）
```

同时 WSLg PulseAudio 的客户端列表里出现 `firefox`，播放期间 `sink-inputs` 有 1 条流（`audio-watch.log` 里 `health=OK ... inputs=1`）。

**为什么不用其他方案**：

| 方案 | 结果 |
|---|---|
| `socat` 转发 unix socket | ❌ PulseAudio 协议会通过 `SCM_RIGHTS` 传 shm fd，socat 默认不转发辅助数据，握手卡死 |
| 软链接 `/run/user/1000/pulse/native -> /mnt/wslg/PulseServer` | ⚠️ 理论可行，但 snap 的 AppArmor 会按解析后的真实路径做检查，有被拒风险（未采用） |
| 会话内再跑一个 PulseAudio + `module-tunnel-sink` | 复杂且多一层缓冲/延迟（未采用） |
| bind mount | ✅ 直接到真实 socket，协议完整、无额外进程 |

### 5.7 恢复手段与看门狗

1. **`audio/fix-audio.ps1`（Windows PowerShell）**：重启 WSL → 重开桌面 → 检查音频。最彻底。
2. **`audio/audio-watchdog.ps1`（Windows 侧循环）**：每 30 秒检查一次 WSLg 音频；卡死则
   `wsl --system -- sh -c "pkill -9 pulseaudio"` 热重启（bind 守护会自动重绑定），日志写 `%TEMP%\wslg-audio-watchdog.log`。
   可作为「任务计划程序」开机启动项常驻。
3. **`audio/audio-watch.sh`（WSL 内）**：每 5 秒记录到 `/tmp/audio-watch.log`，用于事后定位。

### 5.8 音频问题时间线（部分）

| 时间 | 事件 | 状态 |
|---|---|---|
| 00:41 | 用户截图：声音面板「无输出设备」 | 卡死 |
| 00:54 | 首次 `wsl --shutdown` 后：`pactl` 正常、`paplay` 有声 | OK |
| 00:56~01:20 | 多次重启/调试；发现「设置>声音」打开会卡死、snap 路由到哑设备 | 不稳定 |
| 01:26~01:31 | 尝试 socat（失败）→ 改用 bind mount 成功 | 修复路由 |
| 01:44 | GitHub 私有仓库创建（SSH key + gh CLI 设备授权） | — |
| 01:48 | 再次 `wsl --shutdown`，加音频监控 | OK |
| 01:51~01:52 | 浏览器播放：`health=OK inputs=1`，用户确认「一直正常」 | OK |
| 01:54 | 再次卡死（`health=FAIL`，listen 队列 3→6） | 卡死 |
| 01:56~01:57 | 热重启 PulseAudio + 自动重绑定验证通过（`paplay rc=0`、15s 稳定） | 恢复 |

---

## 6. 文件清单

### 6.1 仓库结构

```
wsl-desktop/
├── README.md                          # 使用说明（含剪贴板、声音两章）
├── REPORT.md                          # 本报告
├── wsl-desktop-2604.sh                # 路线 A：26.04 嵌套 GNOME 一键脚本（安装/回滚）
├── wsl-desktop-2604-rdp.sh            # 路线 A 可选：GNOME Remote Desktop（RDP）
├── wsl-desktop-2404-xwayland.sh       # 路线 B：24.04 Xwayland 教程自动化
├── clipboard/
│   ├── clipbridge.sh                  # Windows -> 内层 Wayland 剪贴板桥
│   ├── wsl-clipbridge.service         # 用户级 systemd 服务
│   ├── install-clipbridge.sh          # root 安装（写 /usr/local/bin + 用户单元）
│   ├── enable-clipbridge.sh           # 用户启用/重启
│   ├── start-desktop.sh               # 桌面启动脚本（音频环境 + 剪贴板桥 + 关提示音）
│   └── final-clip-test.sh             # 剪贴板双向自测
└── audio/
    ├── install-audio.sh               # root：PULSE_SERVER/ override / bind 守护 / environment.d
    ├── setup-snap-audio.sh            # 用户：mask pipewire-pulse + 检查 socket 路由
    ├── restart-desktop.sh             # 用 systemd-run 重启桌面会话
    ├── stop-desktop.sh                # 停止/清理嵌套桌面会话（含残留会话管理器）
    ├── fix-audio.ps1                  # Windows：重启 WSL + 重开桌面 + 状态检查
    ├── audio-watchdog.ps1             # Windows：音频卡死看门狗（热重启 PulseAudio）
    └── audio-watch.sh                 # WSL：每 5 秒记录音频状态
```

### 6.2 系统内安装位置

| 路径 | 内容 |
|---|---|
| `/etc/systemd/user/org.gnome.Shell@.service.d/override.conf` | shell 的 devkit 启动参数 + GDK/DISPLAY/PULSE_SERVER |
| `/etc/systemd/system/wslg-pulse-bind.service` | WSLg PulseServer bind mount 守护 |
| `/usr/local/bin/wslg-pulse-bind` | 上述守护脚本 |
| `/usr/local/bin/clipbridge` | 剪贴板桥 |
| `/home/<用户名>/.config/systemd/user/wsl-clipbridge.service` | 剪贴板用户服务（enabled） |
| `/home/<用户名>/.config/environment.d/pulse.conf` | `PULSE_SERVER=...` |
| `/home/<用户名>/start-desktop.sh` | 桌面启动脚本 |
| `/mnt/wslg/PulseServer` | WSLg 音频 socket（系统发行版创建） |
| `/run/user/1000/pulse/native` | 上述 socket 的 bind mount（供 snap 应用使用） |
| `/tmp/clipbridge.log` | 剪贴板桥日志 |
| `/tmp/audio-watch.log` | 音频状态记录 |

> 注意：`/mnt/wslg/*`、`/run/user/*` 在每次 WSL 重启后重建；系统服务 `wslg-pulse-bind` 会自动重新挂载。

---

## 7. 验证矩阵（最终状态）

| 项目 | 方法 | 结果 |
|---|---|---|
| 桌面窗口 | `pgrep -x gnome-shell` / `mutter-devkit` | ✅ 运行中（窗口标题 Mutter Development Kit） |
| 桌面会话托管 | `systemctl --user is-active wsl-desktop-session` | ✅ active（transient 单元） |
| 会话启动自愈（残留会话清理） | 手动启动 / `start-desktop.sh --check` | ✅ 2026-11-12 02:04~02:08 实测 |
| 剪贴板 Linux → Windows | 复制后 `Get-Clipboard -Raw` | ✅ 立即 |
| 剪贴板 Windows → Linux | `clipbridge` 轮询 + `wl-paste` | ✅ 约 0.5~2 秒 |
| 剪贴板中文双向 | 同上 | ✅ |
| 剪贴板服务 | `systemctl --user is-active/is-enabled wsl-clipbridge` | ✅ active / enabled |
| 声音输出设备 | `pactl -s unix:/mnt/wslg/PulseServer info` | ✅ Default Sink: RDPSink |
| 声音输入设备 | 同上 | ✅ Default Source: RDPSource |
| 浏览器（snap Firefox）声音 | WSLg PA 客户端/firefox + sink-inputs | ✅ 有流、可出声（用户确认） |
| snap 路由 | `/run/user/1000/pulse/native` | ✅ WSLg PulseServer 的 bind mount |
| pipewire-pulse | `systemctl --user is-enabled pipewire-pulse.socket` | ✅ masked |
| 热重启 PulseAudio 恢复 | `wsl --system -- pkill -9 pulseaudio` + 自动重绑定 | ✅ 15 秒内恢复、`paplay rc=0` |
| 音频看门狗脚本 | `audio-watchdog.ps1` | ✅ 已提供（可选常驻） |

---

## 8. 已知限制与风险

1. **WSLg 音频仍会周期性卡死**（WSLg 1.0.79 + 本 Windows build 组合下的 bug）：
   - 播放/暂停后、或某些操作后，PulseAudio 会冻结；只能热重启 PA（看门狗）或重启 WSL（`fix-audio.ps1`）恢复；
   - 打开「设置 > 声音」面板也可能触发（实测出现过两次立刻卡死）；
   - 不建议把「长时间稳定播放」当承诺；如需稳定音频，建议 RDP 桌面方案（音频走 RDP 重定向）。
2. **剪贴板只支持纯文本**，图片/文件不同步；同步有约 0.5~2 秒延迟。
3. **嵌套桌面没有登录界面**（除非 RDP），分辨率/全屏受限；部分应用会以独立 WSLg 窗口打开。
4. **性能**：mutter devkit 软件渲染（WSLg 下 `Xwayland glamor: GBM Wayland interfaces not available`，走 sw），视频/动画会慢。
5. **系统升级风险**：GNOME/WSL 升级后 `--devkit` 参数、`mutter-devkit` 行为可能变化；1.0.79 的音频 bug 也可能随 WSLg 更新修复/变化。
6. **RDP 路线未在本机完成**：`wsl-desktop-2604-rdp.sh` 提供了 gnome-remote-desktop 配置（端口 3390、TLS 证书），但此前与 xrdp（占着 3390）冲突且未设置凭据，未做最终验证。

---

## 9. 从零复现步骤（Ubuntu 26.04）

```powershell
# 0) 前提：Windows 10 22H2+/11、WSL2 + WSLg、.wslconfig 里 guiApplications=true
wsl --version
```

```bash
# 1) 发行版内：systemd、桌面组件、mutter-dev-bin
sudo apt-get update
sudo apt-get install -y ubuntu-desktop mutter-dev-bin
# 确保 /etc/wsl.conf 有 [boot] systemd=true

# 2) 放入本仓库脚本
#    （假设仓库在 C:\Users\<用户名>\Desktop\wsl2-nested-gnome-desktop，WSL 内为 /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop）

# 3) root：shell override + 音频 bind 守护 + 启动脚本
sudo bash /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop/wsl-desktop/audio/install-audio.sh

# 4) root：剪贴板桥
sudo bash /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/install-clipbridge.sh

# 5) 用户：启用剪贴板服务 / mask pipewire-pulse / 检查音频路由
bash /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/enable-clipbridge.sh
bash /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop/wsl-desktop/audio/setup-snap-audio.sh

# 6) 重启 WSL（让 WSLg 重新初始化）
#    Windows PowerShell: wsl --shutdown

# 7) 启动桌面（systemd 用户单元托管）
systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh
```

> 详细说明见 [README.md](README.md)；剪贴板与音频的自测脚本见上文。

---

## 10. 排障手册（症状 → 诊断 → 处理）

### 10.0 启动时报 “A graphical session is already running!”

**现象**：桌面窗口被关掉（或 gnome-shell 退出）后，再运行 `~/start-desktop.sh` 连续报：

```
** (process:xxxxx): ERROR **: A graphical session is already running!
已中止
```

**原因**：窗口关闭时 gnome-shell 退出，但 GNOME 的**会话管理器残留**（`org.gnome.SessionManager` 仍被 `gnome-session-service` 占用、`gnome-session@ubuntu.target` 仍 active），新的 gnome-session 认为已有图形会话，直接 abort。

**处理**：

```bash
~/start-desktop.sh --check     # 看 shell 数量 / target / SessionManager / wayland socket
~/stop-desktop.sh              # 清理残留（gnome-session-quit 正常注销 + 兜底 kill）
~/start-desktop.sh             # 重新启动（会先自动清理）
```

`~/start-desktop.sh` 已内置自愈逻辑：检测到残留会先 `gnome-session-quit --logout --no-prompt`，再停 target/服务、兜底 kill，确认 DBus 名释放后才启动；桌面完整在跑时只提示并退出 0（不会重复启动）。2026-11-12 02:04~02:08 实测：手动启动自愈成功，systemd 单元启动 + 重复启动保护均验证通过。

### 10.1 桌面窗口不出来

```bash
echo $DISPLAY; echo $WAYLAND_DISPLAY; ls /mnt/wslg
systemctl --user status 'org.gnome.Shell@ubuntu.service'
journalctl --user -u 'org.gnome.Shell@ubuntu.service' -n 50 --no-pager
```

- `DISPLAY` 空 / `/mnt/wslg` 空 → 检查 `.wslconfig` 的 `guiApplications=true`，`wsl --shutdown`；
- 有报错 `Failed to connect to Wayland display` → override 里缺 `GDK_BACKEND=x11` / `DISPLAY=:0`。

### 10.2 剪贴板 Windows → Linux 不生效

```bash
systemctl --user status wsl-clipbridge
tail -n 20 /tmp/clipbridge.log
DISPLAY=:0 xclip -selection clipboard -o        # 外层 X11 能否读到
WAYLAND_DISPLAY=wayland-0 wl-paste -n           # 内层能否写入
```

- 日志没有新行 → Windows 剪贴板没变、或 `xclip` 读不到（WSLg 卡了）；
- 有日志但应用粘贴不出来 → 应用本身不支持粘贴/剪贴板管理器问题；
- 重启服务：`systemctl --user restart wsl-clipbridge`。

### 10.3 声音（设置里无设备 / 应用无声）

```bash
# 1) 判断 WSLg 音频是否卡死
PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl info
# 2) 卡死 → 热重启（需要 Windows 侧）
#    wsl --system -- sh -c "pkill -9 pulseaudio"
#    或运行 audio/audio-watchdog.ps1 / fix-audio.ps1
# 3) snap 路由是否正常
ls -l /run/user/1000/pulse/native
mountpoint /run/user/1000/pulse/native
pactl -s unix:/run/user/1000/pulse/native info
# 4) 监控日志
tail -n 20 /tmp/audio-watch.log
```

### 10.4 `tail -20 /tmp/xxx` 报 `option used in invalid context`

```bash
tail -n 20 /tmp/xxx
```

### 10.5 关掉桌面窗口后桌面没了

重新拉起：

```bash
systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh
```

---

## 11. 仓库与提交记录

- 开源仓库：本仓库（公开分享版）
- 提交邮箱：`<GitHub邮箱>`（避免 GitHub GH007「private email」拦截）

| 提交 | 内容 |
|---|---|
| `45c4cca` | 初始：WSL2 嵌套 GNOME 桌面脚本（26.04/24.04 路线）、剪贴板桥、音频修复 |
| `9b9e737` | 音频：snap 应用经 bind mount 连接 WSLg；新增音频状态记录脚本 |
| `9d3debf` | 文档：补充私有仓库地址与音频实测结果；fix-audio 增加 socket 挂载检查 |
| `（本报告）` | 新增完整技术报告 `wsl-desktop/REPORT.md`；音频 bind 守护增加「PulseAudio 重启后自动重绑定」；新增 `audio-watchdog.ps1` |
| `（2026-11-12 下午）` | 音频卡死热重启自愈（启动脚本 + Windows 代理看门狗）；剪贴板架构重构（Windows 代理 + 文件邮箱，脱离 WSLg RDP 剪贴板）；新增第 13 章 |

> 约定：此后每次改动都会提交并推送到该私有仓库。

---

## 12. 附录

### 12.1 关键环境自检命令

```bash
# 一次性自检
wsl --version
uname -a
echo "DISPLAY=$DISPLAY WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
ls -l /mnt/wslg/PulseServer /mnt/wslg/.X11-unix/X0
pgrep -a -x gnome-shell
systemctl --user is-active wsl-clipbridge
systemctl is-active wslg-pulse-bind
mountpoint /run/user/1000/pulse/native
PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl info
```

### 12.2 术语表

| 术语 | 说明 |
|---|---|
| WSLg | Windows Subsystem for Linux 的 GUI 支持（Weston + Xwayland + RDP 客户端） |
| WSLg 系统发行版 | WSLg 内部跑的 Azure Linux 发行版，承载 Weston/PulseAudio，可用 `wsl --system` 进入 |
| mutter-devkit | mutter 的 headless/devkit 模式配套查看器，把嵌套桌面显示为普通窗口 |
| devkit 嵌套会话 | 本方案核心：gnome-shell 以 headless 方式运行，mutter-devkit 显示画面 |
| RDPSink / RDPSource | WSLg PulseAudio 的播放/录音虚拟设备 |
| pipewire-pulse | PipeWire 提供的 PulseAudio 兼容服务；本方案中已 mask，改用 bind mount |
| snap 沙箱 | snapd 会给应用设置自己的 `XDG_RUNTIME_DIR` 和 `PULSE_SERVER`，导致默认走会话 pipewire |

### 12.3 参考链接

- Xwayland 教程：<https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912>
- Wayland 教程（26.04 配方来自评论区）：<https://gist.github.com/tdcosta100/7def60bccc8ae32cf9cacb41064b1c0f>
- GNOME 50 移除 X11：<https://itsfoss.com/news/gnome-50-release/>
- Ubuntu 26.04 发布信息：<https://www.cnx-software.com/2026/04/24/ubuntu-26-04-lts-resolute-raccoon-released-with-linux-7-0/>
- WSLg 音频相关 issue（播放暂停后不可恢复）：<https://github.com/microsoft/wslg/issues/1468>
- WSLg 项目：<https://github.com/microsoft/wslg>

### 12.4 本机现网状态快照（2026-11-12 01:57 CST）

```
桌面：gnome-shell 50.1 --devkit 运行中，mutter-devkit 显示中
会话：wsl-desktop-session（systemd 用户 transient 单元）active
剪贴板：wsl-clipbridge active + enabled
音频：WSLg PulseAudio 正常（Default Sink: RDPSink / Source: RDPSource）
      /run/user/1000/pulse/native 为 WSLg PulseServer 的 bind mount
      pipewire-pulse 已 mask
      热重启 PulseAudio 后自动重绑定、paplay rc=0、15 秒稳定
监控：audio-watch 每 5 秒写 /tmp/audio-watch.log
```

---

## 13. 2026-11-12 16:36–17:12：二次事故、根因与剪贴板架构重构

本章记录当天下午「用 `~/start-desktop.sh` / `systemd-run` 启动后**既没有声音也没有剪贴板**」的完整排查与重构过程，结论已合并进脚本与文档。

### 13.1 现象

- 用户从 16:28 起多次用 `~/start-desktop.sh`（以及 `systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh`）启动桌面；
- 桌面窗口正常出现，但：
  - 桌面「设置 > 声音」显示 **输出设备：无输出设备 / 输入设备：无输入设备**；
  - 剪贴板**双向都不通**（此前是「只能复制、不能粘贴」）。
- 16:36 用户提供截图确认上述现象。

### 13.2 现场诊断证据（16:44–16:50）

```bash
# 音频：socket 在，但服务拒绝连接
$ pactl -s unix:/mnt/wslg/PulseServer info
连接失败：拒绝连接
pa_context_connect() 失败：拒绝连接

# 监听队列满（Recv-Q=6 > 本 socket 的 backlog 5）
$ ss -xl | grep PulseServer
u_str LISTEN 6      5   /mnt/wslg/PulseServer 43047

# PulseAudio 日志：RDP 音频队列连续堵死（该文件累计 1095 行）
$ tail -n 3 /mnt/wslg/pulseaudio.log
(15772.362|   0.079) W: [rdp-sink] asyncq.c: q overrun, queuing locally
(15772.442|   0.079) W: [rdp-sink] asyncq.c: q overrun, queuing locally

# Weston 日志：RDP 剪贴板通道卡死 + 旧 clipbridge 的 xclip 请求刷屏
$ grep -n "clipboard_data_source_send" /mnt/wslg/weston.log | tail -2
RDP clipboard_data_source_send ... outstanding RDP data request (client to server)
$ tail -n 2 /mnt/wslg/weston.log
selection request, CLIPBOARD, target UTF8_STRING, property XCLIP_OUT
outstanding selection exist
```

**根因 1（没声音）**：WSLg 的 PulseAudio 卡死——`module-rdp-sink` 的发送队列被堵死（`asyncq.c: q overrun`），PA 主循环随之阻塞；连接 backlog 塞满后，所有客户端（包括 GNOME 的 gvc）连接被拒绝，于是设置里「无输出设备」。
**根因 2（没剪贴板）**：WSLg 的 RDP 剪贴板通道卡死（有一个永不完成的 `outstanding RDP data request`）。旧方案「`xclip` 轮询 WSLg X11 剪贴板 + 依赖 WSLg 原生剪贴板」因此双向全断，且每次轮询都会继续制造 `selection request` → Weston 日志刷屏。旧的 `xclip` 轮询本身也是 RDP 剪贴板卡死的放大器和诱因之一。

### 13.3 修复 1：音频热重启即恢复（不需要 `wsl --shutdown`）

```bash
wsl --system -- sh -c "pkill -9 pulseaudio"
```

WSLGd 会立即拉起新的 PA 实例，几秒内恢复：

- `pactl -s unix:/mnt/wslg/PulseServer info` → `Default Sink: RDPSink`；
- Weston 的播放线程检测到 socket EOF，记录**一次** `Audio sink thread: error while reading from sink socket sizeRead:0. Success`，随后自动重连（`RDP Sink version (1 - 1)`）——本日 16:46:18 / 16:53:50 / 17:03:39 / 17:11:32 四次热重启均如此，**先前报告里「杀了 PA 就必须重启 WSL」的结论被推翻**；
- `wslg-pulse-bind` 守护在约 3 秒内把新 socket 重挂到 `/run/user/1000/pulse/native`（inode 校验一致）；
- 客观验证：`paplay` 播放 6 秒测试音耗时 **6104 ms**（≈实时消费，说明 RDPSink 在正常消费），恢复后 4 分钟探针全 OK，且用户确认在 Windows 扬声器听到测试音；
- 17:11 手工 `pkill -9 pulseaudio` 复测：**<3 秒恢复**，无需任何人工介入。

### 13.4 修复 2：剪贴板架构重构（彻底脱离 WSLg RDP 剪贴板）

**旧方案（已废弃）**

```text
Windows 剪贴板 ⇄ [WSLg RDP 剪贴板通道] ⇄ WSLg X11 (:0) ⇄ xclip 轮询 ⇄ wl-copy ⇄ 内层 GNOME
```

**新方案**

```text
Windows 剪贴板 ⇄ clip-agent.ps1 ⇄ C:\Users\Public\wsl-desktop-clip\{win.txt,linux.req.txt} ⇄ clipbridge ⇄ 内层 GNOME(Wayland)
```

- **Windows 侧 `clip-agent.ps1`**（隐藏常驻，`~/start-desktop.sh` 自动拉起）：
  - 用 **Win32 API**（`OpenClipboard` / `GetClipboardData` / `SetClipboardData` + `CF_UNICODETEXT`）读写剪贴板；
  - 为什么不继续用 PowerShell 的 `Get-Clipboard`：实测另一个进程短暂占用剪贴板时，`Get-Clipboard` 会把代理**永久卡死**（16:56:21 起旧代理心跳停摆、剪贴板单向失联正是这个原因）；Win32 调用失败立即返回，下一轮（250 ms）重试；
  - 变化才写 `win.txt`（避免文件抖动）；读 `linux.req.txt` 写入 Windows 剪贴板，并抑制回环。
- **WSL 侧 `clipbridge`**（systemd 用户服务 `wsl-clipbridge`）：
  - 自动发现内层 GNOME 的 Wayland socket（取 `/run/user/<uid>/wayland-*` 最新的一个，不再写死 `wayland-0`）；
  - `win.txt` 变化 → `wl-copy` 进内层；内层 `wl-paste` 变化 → 写 `linux.req.txt`；
  - 纯文本、UTF-8，中文/多行正常，超过 1 MiB 跳过并记日志。
- 交换目录：`C:\Users\Public\wsl-desktop-clip\`（`win.txt`、`linux.req.txt`、`agent.heartbeat`、`agent.log`、`agent.lock`）。选择 `C:\Users\Public` 是因为 Windows 与 WSL 双方都可写，且路径稳定、可预测。

### 13.5 修复 3：`~/start-desktop.sh` 每次启动自愈

启动顺序（桌面已经在跑时只做 0~2 步然后退出）：

1. `ensure_pulse_socket`：等 `wslg-pulse-bind` 把 PulseServer 挂到 `/run/user/<uid>/pulse/native`（最多 12 秒，inode 校验）；
2. `ensure_audio`：`pactl info` 自检 → 卡死则关掉「设置 > 声音」面板（`pkill -f gnome-control-center`）+ `wsl.exe --system -- pkill -9 pulseaudio` → 最多等 15 秒直到 `Default Sink` 出现；
3. `ensure_clip_agent`：把 `/usr/local/lib/wsl-desktop/clip-agent.ps1` 复制到交换目录 → 心跳（`agent.heartbeat` < 10 秒）检测 → 过期则 `setsid powershell.exe -WindowStyle Hidden -File ...` 重新拉起；
4. `ensure_clipbridge`：`systemctl --user start wsl-clipbridge` 并确认 active；
5. 清理残留会话（原逻辑不变）后 `exec gnome-session`。

配套改动：

- `--check` 一屏输出：`声音服务 / 默认输出 / pulse socket 挂载 / 剪贴板代理(心跳) / 剪贴板桥 / 交换目录 / 会话状态`；
- 脚本内兜底 `WSL_INTEROP`（`systemd-run` 启动时环境可能缺失）：从 `/run/WSL/1_interop`、`/run/WSL/*_interop` 里找可用的；
- 关键能力：**WSL 内部可以执行 Windows 互操作**——`wsl.exe --system ...`（重启系统发行版的 PA）与 `powershell.exe`（拉起代理）在 `systemd-run` 的用户单元里也实测可用。

### 13.6 验证矩阵（17:03–17:12，桌面通过 `systemd-run` 重启）

| 验证项 | 命令 / 证据 | 结果 |
|---|---|---|
| 启动脚本自检输出 | journal: `即将启动桌面：声音=正常 剪贴板代理=在跑 剪贴板桥=active` | ✅ |
| 声音默认输出 | `pactl info` → `Default Sink: RDPSink`、`Default Source: RDPSource` | ✅ |
| 测试音 | 6 秒 44.1kHz 正弦波 `paplay` 耗时 6104 ms（≈实时消费）；用户确认听到 | ✅ |
| pulse socket 挂载 | `/mnt/wslg/PulseServer` 与 `/run/user/1000/pulse/native` 同 inode | ✅ |
| 音频看门狗 | 日志 `audio FAIL` → `audio wedged` → `audio recovered after hot restart`（3 秒） | ✅ |
| 手工杀 PA 复测 | 17:11:32 kill 后 <3 秒 PA 恢复、Weston 自动重连 | ✅ |
| 剪贴板 Windows → 内层 | 设 `WIN2INNER_NEW_1` → `wl-paste` 读到同值；bridge 日志「Windows -> 内层」 | ✅ |
| 剪贴板 内层 → Windows | `wl-copy INNER2WIN_NEW_2` → Windows `Get-Clipboard` 同值；bridge 日志「内层 -> Windows」 | ✅ |
| 代理心跳 | `agent.heartbeat` 持续刷新；`agent.log` 记录双向事件 | ✅ |
| `--check` | 全部项目正常（声音 RDPSink、挂载已挂载、代理在跑、桥 active） | ✅ |

### 13.7 已知风险与后续

- WSLg 1.0.79 的 PA 仍可能周期性卡死（触发因素包括打开声音设置面板、播放提示音、RDP 音频通道抖动等）；现在由「启动自检 + 20 秒看门狗」自动恢复，**通常不需要再 `wsl --shutdown`**；若日志里连续反复 `audio FAIL`，再重启 WSL 或考虑 RDP 桌面方案。
- 剪贴板仅文本（图片/文件不同步），延迟约 0.5~2 秒；代理若被外部杀死，需重跑 `~/start-desktop.sh`（心跳检测会重启它）。
- 旧 `audio/audio-watchdog.ps1` 的看门狗逻辑已内置进 `clip-agent.ps1`，旧脚本仅保留作参考。
- WSLg 自身的 RDP 剪贴板通道仍可能保持卡死状态（`weston.log` 里的 `outstanding RDP data request`），但新方案不再依赖它，可忽略。

### 13.8 本次文件变更

| 文件 | 变更 |
|---|---|
| `wsl-desktop/clipboard/clip-agent.ps1` | **新增**：Windows 侧剪贴板代理 + 音频看门狗（Win32 剪贴板、文件邮箱、单实例锁、日志轮转） |
| `wsl-desktop/clipboard/clipbridge.sh` | **重写**：从 xclip 轮询改为文件邮箱；自动发现内层 Wayland socket |
| `wsl-desktop/clipboard/start-desktop.sh` | 新增音频自检/热重启、代理拉起、桥启动、`--check` 扩展、`WSL_INTEROP` 兜底 |
| `wsl-desktop/clipboard/wsl-clipbridge.service` | 描述更新 |
| `wsl-desktop/clipboard/install-clipbridge.sh` | 安装 `clip-agent.ps1` 到 `/usr/local/lib/wsl-desktop/` |
| `wsl-desktop/clipboard/final-clip-test.sh` | 重写为双向自测（Windows 互操作读回验证） |
| `wsl-desktop/clipboard/enable-clipbridge.sh` | 增加代理心跳提示 |
| `wsl-desktop/audio/audio-watchdog.ps1` | 标注「已内置进代理，保留作参考」 |
| `oneclick/fix-audio.ps1` | 重写：先 `~/start-desktop.sh` 自愈 → 手工热重启 → 最后才重启 WSL；并检查剪贴板状态 |
| `README.md` / `wsl-desktop/README.md` / `wsl-desktop/TROUBLESHOOTING.md` / `oneclick/README.md` | 同步新架构、新排障步骤 |

---

## 14. 公开仓库（脱敏版）：占位符与「填自己的路径」要求

公开仓库由本仓库脱敏生成，个人路径统一替换为占位符。**使用公开仓库前必须替换成本机实际值**，否则命令中的路径不存在，安装/启动会失败。

### 14.1 占位符对照

| 占位符 | 含义 | 由 `show-paths.ps1` 输出的实际值 |
|---|---|---|
| `C:\Users\<用户名>` | Windows 用户目录 | `C:\Users\<Windows 用户名>` |
| `/home/<用户名>` | WSL 用户目录 | `/home/<WSL 用户名>` |
| `<用户名>@<主机名>` | 终端提示符里的用户@主机 | `<WSL 用户名>@<WSL 主机名>` |
| `-u <用户名>` | `wsl` 命令里的 WSL 用户名 | `-u <WSL 用户名>` |
| `<用户名>` / `<主机名>` | 用户名 / 主机名 | 同上 |
| `~/wsl2-nested-gnome-desktop` | 仓库实际位置 | 仓库在 WSL 下的实际路径（如 `/mnt/c/Users/<Windows 用户名>/Desktop/wsl2-nested-gnome-desktop`） |

### 14.2 查看 / 填写脚本：`oneclick/show-paths.ps1`（Windows）/ `oneclick/show-paths.sh`（WSL）

```powershell
# 只查看：实际值 + 所有含占位符的脱敏文件位置 + 对照表
powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1

# 自动替换（会修改文档/脚本；建议先 git status）
powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1 -Apply
```

```bash
# 仓库只在 WSL 里时用这个（功能相同）
bash oneclick/show-paths.sh
bash oneclick/show-paths.sh --apply
```

脚本行为：

1. 探测并打印本机实际值：Windows 用户名 / 用户目录 / 计算机名；WSL 默认发行版、默认用户、home、主机名；仓库在 Windows 与 WSL 下的实际路径（`C:\...` → `/mnt/c/...` 自动换算）；
2. 扫描仓库文本文件，列出**所有含占位符的文件**（相对路径、绝对路径、每类占位符出现次数）——即「公开仓库的脱敏文件位置」清单；
3. 打印「占位符 → 你的实际值」对照表；
4. `-Apply` 按顺序替换（先替换 `C:\Users\<用户名>`、`/home/<用户名>`、`<用户名>@<主机名>`、`-u <用户名>`，再替换其余 `<用户名>`；保留 UTF-8/BOM 与换行；不修改脚本自身）。

### 14.3 入口位置（公开仓库里都能看到要求）

- 根 `README.md` 的「⚠️ 公开仓库（脱敏版）必读」章节
- `wsl-desktop/TROUBLESHOOTING.md` 第 0 节
- `oneclick/README.md` 顶部
- `wsl-desktop/README.md` 顶部
- 本报告第 14 章

> 实际路径版（未脱敏）运行同一脚本会提示「未发现占位符」，可跳过这一步。

---

## 15. 启动方式（2026-11-12 晚）：后台启动、不占用终端

### 15.1 问题

旧版 `~/start-desktop.sh` 在最后 `exec gnome-session`，**直接在 WSL 终端里运行会把终端整个占住**（终端不再返回提示符，关掉终端还可能影响会话）。从 Windows 用 `wsl ... -- bash -lc "systemd-run ..."` 启动虽然会立即返回，但用户很难分清两种方式的差别。

### 15.2 改造：`start-desktop.sh` 模式化

| 命令 | 行为 |
|---|---|
| `~/start-desktop.sh` | **后台启动**：检测到当前不在 systemd 单元里 → `systemd-run --user --unit=wsl-desktop-session --collect --setenv=WSL_DESKTOP_IN_UNIT=1 ~/start-desktop.sh`，打印提示后立即返回（终端释放） |
| `~/start-desktop.sh --check` | 只打印状态（不变） |
| `~/start-desktop.sh --fix` | 只做声音/剪贴板/代理的同步修复，不启动桌面（供 `fix-audio.ps1` 调用） |
| `~/start-desktop.sh --stop` | 停止桌面（转调 `~/stop-desktop.sh`） |
| `~/start-desktop.sh --foreground` | 旧行为：前台 `exec gnome-session`（占用终端，用于调试/排障） |
| `systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh` | **仍然兼容**：脚本检测到 `INVOCATION_ID` / `WSL_DESKTOP_IN_UNIT` 后不再二次 detach，直接在单元里运行；**但单元已存在时会报 `already loaded`（属正常）**，日常请用第一行（脚本会自动清理残留单元） |

实现要点：

- 防重复启动：桌面已经在跑 → 只做 ensure + 提示，不重复起单元；
- `--fix` 是同步的（数秒返回），不会被“后台启动”拖成异步；
- 残留会话清理逻辑不变；
- `fix-audio.ps1` 第 1 步改为调用 `~/start-desktop.sh --fix`，避免后台化后检查过早。

### 15.3 Windows 一键启动脚本

新增 `oneclick/start-desktop.ps1`（以及双击用 `start-desktop.cmd`）：

```powershell
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1            # 后台启动（不占窗口）
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Status    # 查看状态
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Stop      # 停止
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -FixOnly   # 只修声音/剪贴板
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Wait      # 启动并等窗口出现
```

- 默认 `wsl -d <Distro> -- bash -lc '~/start-desktop.sh'`，打印提示 + 状态后返回；WSL 没在运行时 `wsl.exe` 会自动启动它；
- `-Wait` 最多等 90 秒直到 `gnome-shell` 出现；默认只等 15 秒再报告状态；
- `-Distro` 指定发行版名；`-Quiet` 少打印。

### 15.4 实测（2026-11-12 20:45–20:52 CST）

| 场景 | 结果 |
|---|---|
| WSL 终端运行 `~/start-desktop.sh` | 立即打印「桌面已在后台启动…」并**返回提示符**；轮询显示约 2~4 秒后 `gnome-shell` 出现 |
| 用户原命令 `wsl … systemd-run --user --unit=… --collect /home/<用户名>/start-desktop.sh` | 命令 **203 ms** 返回；约 2 秒后桌面出现（不需要占用终端） |
| `oneclick/start-desktop.ps1`（默认） | 约 **1.1 秒**返回；状态显示声音正常、代理在跑、桥 active |
| `oneclick/start-desktop.ps1 -Status` / `-Stop` / `-FixOnly` | 均正常 |
| `oneclick/start-desktop.ps1 -Wait`（先停止桌面再启动） | 约 **3.5 秒**完成并打印「✅ 桌面已启动」 |
| `start-desktop.cmd -Status`（双击等价） | 正常输出状态 |
| `~/start-desktop.sh --check` | 会话/声音/剪贴板全绿（`gnome-shell 1 个`、`RDPSink`、`pulse socket 已挂载`、代理在跑、桥 active） |
| 残留单元场景（关窗口后 unit 仍 active、`gnome-shell` 0）→ `~/start-desktop.sh` | **2.14 秒**返回；打印「检测到残留的桌面单元…正在清理…」并自动重启；约 5 秒后 `gnome-shell`=1、MainPID 更新 |
| 桌面已在运行时再次 `~/start-desktop.sh` | **0.37 秒**返回，打印「桌面已经在运行（gnome-shell 在跑），无需重复启动」+ 声音/剪贴板状态 |
| `C:\windows\System32` 下用完整路径运行 `start-desktop.ps1`（桌面已在运行） | **1.66 秒**返回；「✅ 桌面已经在运行（没有重复启动）」+ 会话状态正常 |
| `C:\` 下运行 `start-desktop.cmd -Status`（任意目录） | 正常输出状态；`%~dp0` 自定位生效 |
| `start-desktop.ps1 -Stop` 后再 `start-desktop.ps1` 启动 | 停止约 1 秒；启动 **3.57 秒**完成并打印「✅ 桌面已启动」 |

### 15.5 常见误用与报错（2026-11-12 23:26 用户现场 + 23:30 修复复测）

用户现场（Windows PowerShell 5.1，当前目录 `C:\windows\System32`）：

1. 连续 3 次执行原命令
   `wsl -d Ubuntu -u <用户名> -- bash -lc "systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh"`，均报：
   `Failed to start transient service unit: Unit wsl-desktop-session.service was already loaded or has a fragment file.`
2. 执行 `powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1`，报：
   `-File 形式参数的实际参数“.\oneclick\start-desktop.ps1”不存在。`

排查（`systemctl --user status wsl-desktop-session`）：

- 单元 `active (running)` 已 2 小时 36 分，但 `gnome-shell` 进程数为 **0**，只剩
  `gnome-session-init-worker` / `gnome-session-service` / `gnome-session-ctl`；
- 即：**关掉桌面窗口后桌面本体已退出，但 systemd 单元和会话管理器残留** —— 所以 `systemd-run`
  认为单元已存在、拒绝重复创建；
- 第二个报错是相对路径问题：`.\` 相对当前目录（`C:\windows\System32`），仓库不在那里，
  与脚本本身无关。

根因：

1. 用户仍在反复粘贴**旧的手工 `systemd-run` 命令**（它只在“单元不存在”的首次启动有效；
   单元已存在时必然报 already loaded）；
2. 关窗口后的**残留单元没有被自动清理**——旧实现虽然也在 `systemd-run` 前 `stop`，
   但对 loaded/failed 状态处理不完整，且没有任何提示；
3. 文档仍把 `systemd-run` 写成“推荐的重开方式”，没有解释 `already loaded` 的含义，
   也没说明 PowerShell 相对路径的目录前提。

本次修复：

| 改动 | 说明 |
|---|---|
| `start-desktop.sh` 自动清理残留单元 | 启动前检测 `unit` 是否 active → 打印「检测到残留的桌面单元…正在清理…」→ `systemctl --user stop` + `reset-failed` + 最多等 10 秒退出 → 再 `systemd-run` |
| `start-desktop.sh` 不再静默回退前台 | `systemd-run` 失败时打印明确原因/建议并 `exit 1`（避免“后台启动失败却在当前终端跑起来”再次占用终端）；只有显式 `--foreground` 才前台 |
| `--check` 新增「会话状态」行 | `正常（桌面在运行）` / `残留（unit 在跑但桌面已退出，运行 ~/start-desktop.sh 会自动清理并重启）` / `未运行` |
| `--fix` 提示残留 | 只修声音/剪贴板时若发现残留单元，给出“运行 ~/start-desktop.sh 会自动清理并启动”的提示 |
| 已运行时提示更清楚 | 「桌面已经在运行…无需重复启动」+「重复手动执行 systemd-run 同一单元会报 already loaded，这是正常的」 |
| `start-desktop.ps1` 状态更清楚 | 过滤显示「会话状态」；区分「✅ 桌面已经在运行（没有重复启动）」/「✅ 桌面已启动」/「已清理残留桌面单元并启动」；结尾提示任意目录运行 + systemd-run 报错属正常 |
| `start-desktop.cmd` | 确认 `%~dp0` 自定位，任意目录/双击都可用（注释写明） |
| 文档 | 新增 TROUBLESHOOTING 4.5（两个报错的含义与解法）；4.3/4.4、README、oneclick/README、wsl-desktop/README 全部改为推荐 `~/start-desktop.sh`，并把 `systemd-run` 标注为“仅首次/备用，报 already loaded 属正常” |

复测（23:30–23:35）：

| 场景 | 结果 |
|---|---|
| 手工构造残留单元（关窗口：`pkill -x gnome-shell`，unit 仍 active）→ `~/start-desktop.sh` | **2.14 秒**返回；打印「检测到残留的桌面单元（unit 还在，但桌面窗口已退出），正在清理…」→「桌面已在后台启动」；约 5 秒后 `gnome-shell`=1、新 MainPID |
| 桌面已在运行时再次 `~/start-desktop.sh` | 0.37 秒返回，打印「桌面已经在运行（gnome-shell 在跑），无需重复启动」+ 声音/剪贴板状态 |
| `C:\windows\System32` 下用完整路径运行 `start-desktop.ps1`（桌面在运行） | 1.66 秒返回；「✅ 桌面已经在运行（没有重复启动）」+ 会话状态正常 |
| `C:\` 下运行 `start-desktop.cmd -Status` | 正常（`%~dp0` 自定位） |
| `start-desktop.ps1 -Stop` → 再启动 | 停止约 1 秒；启动 **3.57 秒**完成并打印「✅ 桌面已启动」 |
| `~/start-desktop.sh --check` | 新增「会话状态: 正常（桌面在运行）」，其余全绿 |

用户可复制粘贴的最终答案（Windows 任意目录，不依赖仓库路径）：

```powershell
# 启动（幂等，立即返回，不占终端）
wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"

# 查看状态（含会话状态：正常 / 残留 / 未运行）
wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh --check"

# 或双击 oneclick\start-desktop.cmd（%~dp0 自动定位，和当前目录无关）
```

### 15.6 任务栏图标闪烁 /「Desktop Icons NG 正在 X11Wayland 下运行」警告（2026-11-13 00:15–00:45 排查）

**现象**：任务栏（dock）里一个齿轮图标约每 1.5 秒闪出来又消失；随后弹出白底「警告」窗口，内容为
`Desktop Icons NG 正在 X11Wayland 下运行` / `您的系统似乎被配置为强制 GTK 使用 X11…`；
journal 刷 `meta_window_set_stack_position_no_sync` 断言。用户反馈「没安装（flatpak）之前就一直弹」。

**定位过程**：

- 用 `PrintWindow` 定时截取 `Mutter Development Kit` 窗口，逐帧比对：闪烁的是 dock 里一个“未知应用”图标
  （通用齿轮图标 `application-x-executable`），每隔 ≈1.5 秒出现 0.2–0.3 秒；
- 通过 **AT-SPI 无障碍树**（`gi.repository.Atspi`）读到 `gjs` 应用下有 `[alert] 警告`，文字正是
  `Desktop Icons NG 正在 X11Wayland 下运行` → 弹窗来自 **ding 扩展**；
- 读 ding 的 `/proc/<pid>/environ`：`GDK_BACKEND=x11`、`DISPLAY=:0`、`WAYLAND_DISPLAY=wayland-0` ——
  继承自 `gnome-shell` 的 systemd override（`install-audio.sh` 为了 mutter-devkit 显示而设置）；
- 嵌套会话是 `mutter --devkit --no-x11`，ding 以 X11Wayland 方式运行，桌面窗口会被反复重建
  → 每次都重新弹一次警告、dock 图标跟着闪。

**修复**（已进 `start-desktop.sh` 的 `ensure_ding_off`，每次启动/`--fix` 自动执行）：

1. `gsettings set org.gnome.shell.extensions.ding check-x11wayland false`：不再弹警告；
2. 把 `ding@rastersoft.com` 合并进 `org.gnome.shell disabled-extensions`（禁用桌面图标，
   避免桌面窗口反复重建/闪烁；嵌套桌面不需要桌面图标）；
3. `--check` 新增「桌面图标扩展(ding): 已禁用（防闪烁）」状态行；TROUBLESHOOTING 新增 4.7。

恢复桌面图标：`gnome-extensions enable ding@rastersoft.com`（警告不会再弹）。

### 15.7 任务栏齿轮图标反复闪 ≈ 剪贴板桥轮询（2026-11-13 01:30–01:55 排查）

**现象**：dock 里灰色齿轮图标（左侧带橙色“运行”点）每隔 1~2 秒闪出又消失
（用户截图对比：有/无该图标）。不是 15.6 的 ding 警告（那个已修）。

**定位**：

- 停掉 `wsl-clipbridge` → 闪烁**立刻消失**（dock 区域亮像素统计 flips 从 8~17 降到 0）；
- 手动循环跑 `wl-paste` → 闪烁**立刻复现**（flips=17），确认与剪贴板桥轮询有关；
- `WAYLAND_DEBUG=1 wl-paste` 显示它每次都创建 **xdg_toplevel 窗口（title "wl-clipboard"）**；
  Ubuntu Dock 把这个没有 .desktop 的临时窗口当成“未知应用”画出齿轮图标 → 轮询多快就闪多快；
- 试过 `wl-paste --watch`：mutter 不支持 wlroots data-control 协议
  （`Watch mode requires a compositor that supports the wlroots data-control protocol`），不能用常驻监听；
  也试过 GTK3 clipboard watcher（owner-change），嵌套会话里读不到剪贴板，放弃。

**修复**（最终方案：把同步搬进 gnome-shell，彻底不产生窗口）：

1. 新增 GNOME Shell 扩展 `clipbridge@wsl-desktop`
   （`wsl-desktop/clipboard/extension/{metadata.json,extension.js}`，安装到
   `/usr/share/gnome-shell/extensions/`）：在 shell 进程内部用 `St.Clipboard`
   直接读写剪贴板，用两个 `GLib.timeout` 轮询（Windows 侧文件 400ms、内层剪贴板 400ms），
   通过 `win.txt` / `linux.req.txt` 与 Windows 代理交换内容 —— **没有窗口、不抢焦点**；
2. `install-clipbridge.sh` 安装该扩展；`start-desktop.sh` 的 `ensure_desktop_tweaks`
   在启动/`--fix` 时把 `clipbridge@wsl-desktop` 合并进 `org.gnome.shell enabled-extensions`，
   并保留 Dock 的“运行中程序”图标（`show-running true`）；
3. `clipbridge.sh`：检测到扩展启用后只做 keepalive（不再轮询 `wl-paste`）；
   未启用扩展时仍回退旧轮询（兼容旧环境）；
4. `--check` 新增「剪贴板同步: GNOME Shell 扩展（无窗口、不抢焦点）」等状态行；
5. TROUBLESHOOTING 4.8 重写（原因 / 方案 / 手动启用）。

**验证**：扩展启用、Dock 运行图标开启、`wsl-clipbridge` 在跑的情况下，
dock 区域测 40 帧 **flips=0**（不再闪烁）；剪贴板双向实测：
Windows→内层 `FINAL-WIN-1`、内层→Windows `FINAL-LIN-2` 均通过。

> 备注：旧规避方案（关闭 Dock 运行图标）已废弃；现在运行图标保留。若临时想回退：
> `gsettings set org.gnome.shell.extensions.dash-to-dock show-running false`。

### 15.8 应用窗口“跳出”Ubuntu 桌面 ≈ gnome-shell 强制 GDK_BACKEND=x11（2026-11-13 02:30–02:50 排查修复）

**现象**：用户反馈“这个程序跳出了 ubuntu，单开了一个新的窗口”。在 Windows 任务栏里能看到
**「软件更新器 (Ubuntu)」「计算器 (Ubuntu)」** 这类单独按钮，缩略图是应用窗口；
但 Ubuntu 桌面（「Mutter Development Kit」窗口）里看不到它们（或它们浮在桌面窗口上层）。

**定位**（Windows `EnumWindows` + WSL 进程环境对比）：

- Windows 侧枚举到同一个 `msrdc` 进程下 **3 个顶层窗口**：
  `Mutter Development Kit (Ubuntu)`、`计算器 (Ubuntu)`（1181,-5,1464,448）、
  `软件更新器 (Ubuntu)`（637,485,1078,628）——后两个就是“跑出去”的应用；
- 跑出去的进程（`update-manager`、`gnome-calculator`）父进程都是 **gnome-shell**，
  环境里带 `GDK_BACKEND=x11`、`DISPLAY=:0` → 作为 X11 客户端连到 WSLg 外层的 Xwayland `:0`；
- 而通过 D-Bus 激活的 `gnome-calendar`（父进程 `systemd --user`，环境里没有 `GDK_BACKEND`）
  走 `WAYLAND_DISPLAY=wayland-0` + `XDG_RUNTIME_DIR=/run/user/1000` → 连到嵌套 mutter → 正常显示在桌面里；
- 根因：为让桌面窗口（mutter-devkit）在 WSLg 里显示，`gnome-shell` 的 systemd override 设置了
  `GDK_BACKEND=x11`；gnome-shell 启动应用时把环境传给子进程，于是所有 GTK 应用都被强制走外层 X11。

**修复**（写进 `install-audio.sh` + `start-desktop.sh`，可自愈）：

1. `gnome-shell` 的 override 去掉 `Environment=GDK_BACKEND=x11`，保留
   `DISPLAY=:0`、`WAYLAND_DISPLAY=wayland-0`、`PULSE_SERVER`（应用因此走嵌套 Wayland）；
2. 新增包装脚本 `wsl-desktop/audio/mutter-devkit-wrapper.sh`，安装为
   `/usr/libexec/mutter-devkit`（原版保留为 `/usr/libexec/mutter-devkit.real`），
   只有桌面窗口进程强制 `GDK_BACKEND=x11 DISPLAY=:0`；
3. `start-desktop.sh` 新增 `ensure_nested_windows()`：每次启动/`--fix` 检查上述两项，
   apt 升级 mutter-dev-bin 把原版还原后会自动修复（通过 WSL 互操作 `wsl.exe -u root` 写文件，
   再 `systemctl --user daemon-reload`）；
4. `--check` 新增「应用窗口归属」行；TROUBLESHOOTING 新增 4.9（含验证与恢复默认方法）。

**验证**（2026-11-13 02:40–02:48 CST）：

- 重启桌面后，Windows 顶层窗口只剩 `Mutter Development Kit (Ubuntu)`；
- 用 gnome-shell 的确切环境启动 Firefox（snap）、设置、计算器：全部显示在 Ubuntu 桌面窗口内部，
  任务栏不再出现单独按钮；
- `~/start-desktop.sh --check` 显示「应用窗口归属: 在 Ubuntu 桌面窗口内（嵌套 Wayland）」；
- 修剪后的桌面截图（PrintWindow）可见 Firefox、设置、计算器都在「Mutter Development Kit」窗口内。

| 文件 | 改动 |
|---|---|
| `wsl-desktop/audio/install-audio.sh` | override 去掉 GDK_BACKEND、加 WAYLAND_DISPLAY；安装 mutter-devkit 包装脚本；部署脚本去 CRLF |
| `wsl-desktop/audio/mutter-devkit-wrapper.sh` | 新增：仅给 mutter-devkit 强制 X11 |
| `wsl-desktop/clipboard/start-desktop.sh` | 新增 `ensure_nested_windows()`（自愈）；`--check` 新增「应用窗口归属」 |
| `oneclick/start-desktop.ps1` | 状态过滤匹配「应用窗口归属」 |
| `oneclick/install.ps1` | 载荷更新；解包后统一去 CRLF |
| `wsl-desktop/TROUBLESHOOTING.md` | 新增 4.9；速查表/现象表补充 |
| `wsl-desktop/REPORT.md` | 本节 |

> 限制：纯 X11 应用（少数老程序、部分 Java/Electron）没有嵌套 X 服务器，仍会显示为 Windows 外层窗口。
> 恢复默认（回到旧行为）见 TROUBLESHOOTING 4.9。

### 15.9 剪贴板突然失效 ≈ 桌面崩溃后扩展被 GNOME 自动禁用（2026-11-13 03:00 排查）

**现象**：用户反馈“复制粘贴挂了”。`~/start-desktop.sh --check` 显示
「剪贴板代理(Windows): 在跑」「剪贴板桥(服务): active」，但 Windows ⇄ Linux 双向都不同步。

**定位**：

- `gnome-extensions info clipbridge@wsl-desktop`：**已启用: 否，状态: INITIALIZED**；
- `gsettings get org.gnome.shell disable-user-extensions` = **true**；
- journal：02:38:27 `Started org.gnome.Shell-disable-extensions.service - Disable GNOME Shell extensions after failure`
  —— 为排查 15.8 调 `GDK_BACKEND` 时 gnome-shell 崩过一次，GNOME 自动禁用了所有用户扩展
  （并在 `/run/user/1000/gnome-shell-disable-extensions` 留下标记文件）；
- 扩展没跑 → 内层剪贴板没人同步；Windows 代理和 `wsl-clipbridge` 都正常，所以 `--check` 前两行是绿的，
  旧版 `--check` 的「剪贴板同步」行也误报为“扩展正常”（只看了 enabled-extensions 列表）。

**修复**（写进 `start-desktop.sh` 的 `ensure_desktop_tweaks`，每次启动/`--fix` 自动执行）：

1. `gsettings set org.gnome.shell disable-user-extensions false`；
2. 删除标记文件 `$XDG_RUNTIME_DIR/gnome-shell-disable-extensions`；
3. 桌面在跑时顺便 `gnome-extensions enable clipbridge@wsl-desktop`（立即生效）；
4. `--check` 的「剪贴板同步」行改为真实状态：
   正常（扩展在跑）/ 扩展被禁用（给出修复提示）/ 旧轮询 / 桌面未运行。

**验证**（03:02–03:03 CST）：重启用后 `gnome-extensions info` 显示「已启用: 是」「状态: ACTIVE」；
剪贴板双向实测 Windows→Linux `CLIPWIN-030229`、Linux→Windows `CLIPLIN-030229` 均通过。

| 文件 | 改动 |
|---|---|
| `wsl-desktop/clipboard/start-desktop.sh` | 启动/`--fix` 恢复 `disable-user-extensions`；`--check` 剪贴板行改为真实扩展状态 |
| `wsl-desktop/TROUBLESHOOTING.md` | 第 6 章新增「④ 双向都不通：扩展被自动禁用」；速查表/报错表补充 |
| `wsl-desktop/REPORT.md` | 本节 |


## 16. 跨发行版移植：Fedora 45 / Kali 2026.3 / Oracle Linux 10（2026-11-22 23:20 – 2026-11-23 00:40 CST）

**目标**：原方案只支持 Ubuntu 26.04（GNOME 50 + `mutter-devkit`）。本次把同一套「桌面窗口 + 剪贴板 + 声音 + 一键脚本」移植到
Fedora 45（GNOME 51）、Kali 2026.3（GNOME 50）、Oracle Linux 10.3（GNOME 47，RHEL 10 系），并保持 Ubuntu 行为不变。

### 16.1 环境矩阵

| 发行版 | GNOME Shell | mutter | gnome-session | `mutter-devkit` | 本项目模式 | 桌面窗口标题 |
|---|---|---|---|---|---|---|
| Ubuntu 26.04.1 | 50.1 | 50.1 | 50.x | ✅ `mutter-dev-bin` | devkit | `Mutter Development Kit (Ubuntu)` |
| Fedora 45 | 51.1 | 51.1 | 51.x | ✅ `mutter-devkit` | devkit | `Mutter Development Kit (FedoraLinux-45)` |
| Kali 2026.3 | 50.5 | 50.5 | 50.x | ✅ `mutter-dev-bin` | devkit | `Mutter Development Kit (kali-linux)` |
| Oracle Linux 10.3 | 47.8（固定） | 47.5 | 46.0 | ❌ RHEL 没打包 | **nested** | `gnome-shell (oracle-linux-10)` |

### 16.2 移植中遇到的关键差异（按发现顺序）

1. **Oracle Linux 10 的 WSL 镜像什么都没准备**：
   `ps -p 1 -o comm=` 输出 `init(oracle-lin`（systemd 没开）、`getent passwd 1000` 为空（没有普通用户）、
   `dnf repolist` 只有 `base`/`latest`（没有 AppStream，GNOME 全在 AppStream）。
   安装器现在会写 `/etc/wsl.conf`（`[boot] systemd=true` + `[user] default=u`）、创建 uid 1000 用户、
   添加 `https://yum.oracle.com/repo/OracleLinux/OL10/appstream/x86_64/`（官方 WSL 镜像没带），
   然后返回退出码 3 让 Windows 侧 `wsl --terminate` 后重试。
2. **RHEL/Oracle 没有 `mutter-devkit`**：AppStream 同时提供 `gnome-shell 47.4/47.8/49.4/49.5` 和 `mutter 47.5/49.4`，
   但 `repoquery -l mutter` 里没有 `/usr/libexec/mutter-devkit`，`--whatprovides '*/mutter-devkit'` 为空；
   而 GNOME 49 已经移除了 `--nested`。结论：**只能用 GNOME 47.8 的 `gnome-shell --nested`**，安装器固定 47。
3. **GNOME 47 的 nested 模式不能用 gnome-session 托管**：gnome-session 46 直接启动 shell，
   GNOME 49+ 才有的 `org.gnome.Shell@.service` override 在它这里不生效。改成 `start-desktop.sh` 直接在 systemd 用户单元里跑
   `gnome-shell --nested --no-x11 --wayland-display=wayland-1`；因此 `--check` 里「SessionManager DBus: 空闲」是正常的。
4. **`/tmp/.X11-unix` 是只读挂载**：nested 模式默认会拉 Xwayland，报
   `Failed to start X Wayland: Directory "/tmp/.X11-unix" is not writable`（WSLg 的只读挂载）→ 加 `--no-x11`（X11-only 应用不能跑）。
5. **WSLg 的 `wayland-0` 软链**：Fedora/Kali/OL 的 `/run/user/1000/wayland-0` 是指向 `/mnt/wslg/runtime-dir` 的软链
   （Ubuntu 26.04 没有），mutter 锁不到它就会自动改用 `wayland-1`；如果 override 里写死 `WAYLAND_DISPLAY=wayland-0`，
   应用会连到 WSLg 外层，窗口就“跑出去”了。修复：override + 启动脚本统一显式 `--wayland-display=wayland-1` + `WAYLAND_DISPLAY=wayland-1`；
   nested 模式会挑空闲的 `wayland-N` 并清理上次崩溃残留的 socket。
6. **PipeWire 是硬依赖**：GNOME 49+ 的 mutter/devkit 启动时要连 PipeWire，Fedora 上 PipeWire 没起来时
   Shell 直接退出：`Context got an error: Failed to connect pipewire context`。
   `install.sh` 和 `start-desktop.sh` 现在都会先 `systemctl --user start pipewire.socket pipewire.service wireplumber.service`。
7. **包名/工具差异**：RHEL 10 没有 `gnome-terminal`（改用 `ptyxis`）、没有 `wl-clipboard`；
   Debian 系是 `pipewire-pulse`（不是 Fedora 的 `pipewire-pulseaudio`）；
   Kali 的 `kali-desktop-gnome` 会拖 300+ 包，改用最小 GNOME 集合。
8. **最小镜像没有 `awk`**（Fedora/OL）：`install-audio.sh` / `install-clipbridge.sh` 里的用户探测改成 POSIX `while read`；
   `wsl-clipbridge.service` 去掉写死的 `/run/user/1000`（systemd 用户单元自带 `XDG_RUNTIME_DIR`）。
9. **一键脚本重写**：`oneclick/install.ps1` 增加 `-Distro` / `-User` / `-All` / `-SkipPackages`（兼容 `-SkipApt`）/
   `-NoStart` / `-DryRun`，自动检测 systemd（退出码 3 → `wsl --terminate` 后重试）、自动解析普通用户；
   `start-desktop.ps1` / `fix-audio.ps1` / `restart-desktop.ps1` 也支持 `-Distro`/`-User` 并自动发现发行版。

### 16.3 验证矩阵（2026-11-22 23:52 – 2026-11-23 00:40）

| 发行版 | 桌面窗口 | 应用留在桌面内 | Windows→Linux | Linux→Windows | 声音 |
|---|---|---|---|---|---|
| Ubuntu 26.04 | ✅ `Mutter Development Kit (Ubuntu)` | ✅ 计算器在桌面内 | ✅ `UBU-WIN2-031500` | ✅ `UBU-LIN2-031500` | ✅ `RDPSink` |
| Fedora 45 | ✅ `Mutter Development Kit (FedoraLinux-45)` | ✅ 计算器在桌面内（无新 Windows 窗口） | ✅ journal `win -> inner (14 chars)` | ✅ Windows 剪贴板收到 `FED-LIN-030700` | ✅ `RDPSink` |
| Kali 2026.3 | ✅ | ✅ | ✅ | ✅ | ✅ |
| Oracle Linux 10.3 | ✅ `gnome-shell (oracle-linux-10)` | ✅ 计算器在桌面内 | ✅ 扩展 ACTIVE + `win -> inner` 日志 | ⏳ 仓库没有 `wl-clipboard`，命令行模拟无法复制（扩展 ACTIVE，同一实现已在 Fedora/Ubuntu 双向实测） | ✅ `RDPSink` |

> Kali 验证命令（与 Ubuntu 相同）：`~/start-desktop.sh --check`、`wl-copy`/`wl-paste` 双向。
> Oracle Linux 10 的 `Mutter Development Kit` 标题不会出现（nested 模式），窗口标题是 `gnome-shell (oracle-linux-10)`，标题会随前台应用变化。

### 16.4 已知限制（新增）

- **同时开多个发行版桌面 → 剪贴板互相抢**：Windows 侧交换目录全局一个（`C:\Users\Public\wsl-desktop-clip`），
  多个桌面的扩展会同时写 `linux.req.txt` / 读 `win.txt`，表现为剪贴板“时好时坏”。建议一次只开一个桌面。
- **Oracle Linux 10 是受限的 nested 会话**：没有完整 gnome-session（无 gsd/会话服务），没有 Xwayland；
  dnf 升级 `gnome-shell` 到 49 会失去 nested（重跑安装器会装回 47）。
- **Kali 用最小 GNOME**（非 `kali-desktop-gnome` 全套）：需要 Kali 菜单/工具自行安装。

### 16.5 文件变更

| 文件 | 改动 |
|---|---|
| `wsl-desktop/install.sh` | 新增：跨发行版安装器（systemd/用户/apt-dnf/包集合/devkit-vs-nested） |
| `wsl-desktop/audio/install-audio.sh` | devkit 检测、`wayland-1`、无 awk、任意用户 |
| `wsl-desktop/audio/stop-desktop.sh` | 通用 gnome-session target |
| `wsl-desktop/clipboard/start-desktop.sh` | 模式检测（devkit/nested）、PipeWire、wayland-N、跨发行版文案 |
| `wsl-desktop/clipboard/install-clipbridge.sh` | 无 awk、任意用户 |
| `wsl-desktop/clipboard/wsl-clipbridge.service` | 去掉写死的 XDG_RUNTIME_DIR |
| `wsl-desktop/clipboard/extension/metadata.json` | 支持 GNOME 51 |
| `oneclick/install.ps1` | 重写：-Distro/-User/-All/-SkipPackages/-NoStart/-DryRun，自动 systemd/用户 |
| `oneclick/start-desktop.ps1` | -User、自动发行版/用户、桌面模式显示 |
| `oneclick/fix-audio.ps1` / `restart-desktop.ps1` | -User、自动发行版/用户 |
| `README.md` / `oneclick/README.md` / `wsl-desktop/TROUBLESHOOTING.md` / `wsl-desktop/README.md` | 多发行版说明、4.10、6⑤ 等 |

---

*报告结束。后续修改请同步更新本文件并推送到私有仓库。*
