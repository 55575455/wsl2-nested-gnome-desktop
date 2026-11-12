# WSL2「桌面一键脚本」：Ubuntu 26.04 / 24.04

> 开源分享版（公开仓库）；完整文档见 [README.md](../README.md)、[TROUBLESHOOTING.md](TROUBLESHOOTING.md)、[REPORT.md](REPORT.md)。
> 完整技术报告（架构、根因分析、验证矩阵、排障手册）：[REPORT.md](REPORT.md)
>
> ⚠️ **公开仓库（脱敏版）用户**：本文里的 `C:\Users\<用户名>`、`/home/<用户名>`、`~/wsl2-nested-gnome-desktop` 都是占位符。
> **先运行** `oneclick/show-paths.ps1`（Windows）或 `bash oneclick/show-paths.sh`（WSL），按输出填成本机实际路径；不填的话路径不存在。
> （实际路径版会提示「未发现占位符」，跳过即可。）

## 先说清楚：为什么没有「Xwayland + Ubuntu 26.04 一键命令」

**这条路线在 Ubuntu 26.04 上已经死了，不是脚本能修的问题。**

- Ubuntu 26.04（GNOME 50）**移除了 X11 会话**，GDM 也**移除了 X11 支持**；
- 原 Xwayland 教程的核心是「用 Xwayland 冒充 `/usr/bin/Xorg`，让 GDM 启动 GNOME **X11 会话**」——26.04 里这两个前提都不存在；
- 教程评论区 2026-07 已确认：**"It doesn't work with 26.04"**，之后没有新的成功方案。

所以本目录给的是两条**实际能跑**的路线：

| 路线 | 适用发行版 | 效果 | 本质 |
|---|---|---|---|
| A（推荐给 26.04） | Ubuntu 26.04 | 一个 GNOME 桌面窗口，无登录界面；可加 RDP 补全屏/剪贴板 | 社区 `mutter-devkit` 嵌套方案，**不是 Xwayland** |
| B（真正的 Xwayland 教程） | **只能** Ubuntu 24.04 | 带 GDM 登录界面的完整桌面（原教程效果） | 替换 Xorg + Xwayland + GDM |

> 想要「Xwayland 教程的完整效果」，最省事的做法是**新建一个 Ubuntu 24.04 WSL 实例**跑路线 B，而不是在 26.04 上硬改。

## 文件

| 文件 | 用途 |
|---|---|
| `TROUBLESHOOTING.md` | 🚑 **故障排除指南**（复制粘贴即可，遇到问题先看这个） |
| `wsl-desktop-2604.sh` | 路线 A：Ubuntu 26.04 嵌套 GNOME 桌面（安装 + 配置 + 启动脚本 + `--rollback`） |
| `wsl-desktop-2604-rdp.sh` | 路线 A 可选增强：GNOME Remote Desktop（RDP），获得登录界面、全屏、剪贴板 |
| `wsl-desktop-2404-xwayland.sh` | 路线 B：把 Xwayland 教程自动化（安装 + 配置 + `--rollback`） |
| `clipboard/` | 路线 A 的剪贴板：`clip-agent.ps1`（Windows 侧代理，兼音频看门狗）+ `clipbridge.sh`（WSL 侧桥）+ systemd 用户服务（见下文「剪贴板」） |
| `audio/` | 路线 A 的声音：环境变量安装脚本、桌面重启脚本、一键修复脚本（见下文「声音」） |
| `../oneclick/` | ⚡ 给“不会 Linux”的人的一键脚本（安装 / 修声音 / 重开桌面，自包含） |

脚本都支持 `-h/--help`；**默认只显示计划，加 `--yes` 才执行**。

## 路线 A：Ubuntu 26.04（嵌套 GNOME）

前提：WSL2 + WSLg（Windows 11 或较新的 Windows 10 22H2 + Store 版 WSL）、systemd、约 5 GB 磁盘。

```powershell
# 1) 安装发行版（已安装可跳过；名称以 wsl -l -o 为准）
wsl --install -d Ubuntu-26.04

# 2) 第一次打开 Ubuntu 26.04，创建普通用户后，在 Ubuntu 终端里执行：
#    （路径按你的工作目录调整；本机为 C:\Users\<用户名>\Desktop\wsl2-nested-gnome-desktop）
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2604.sh --yes

# 3) 重启 WSL
wsl.exe --shutdown

# 4) 重新打开 Ubuntu 26.04 终端，启动桌面
~/start-desktop.sh
```

可选：RDP（想要登录界面 / 全屏 / 剪贴板）

```bash
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2604-rdp.sh
wsl.exe --shutdown
~/start-desktop.sh
# 然后在 Windows「远程桌面连接」里连 localhost:3390
```

也可以从 Windows 侧「一条命令」跑安装（仍是 root 执行；桌面必须以普通用户启动）：

```powershell
wsl -d Ubuntu-26.04 -u root -- bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2604.sh --yes
wsl.exe --shutdown
# 重开 Ubuntu 终端后：~/start-desktop.sh
```

## 剪贴板：Linux ⇄ Windows 双向（2026-11-12 起为新方案）

**旧方案已废弃**：早期用「WSLg 原生 RDP 剪贴板 + 轮询 `xclip`」做单向补丁。实测发现 WSLg 的 RDP 剪贴板通道会卡死（`weston.log` 里大量 `outstanding RDP data request` / `outstanding selection exist`，`xclip` 每次都要等超时），既不可靠又会拖累 Weston。

**现在的方案（不依赖 WSLg 剪贴板）**：

| 部件 | 位置 | 作用 |
|---|---|---|
| `clip-agent.ps1` | Windows（隐藏常驻，由 `~/start-desktop.sh` 自动拉起） | 用 Win32 API 读写 Windows 剪贴板；同时兼职音频看门狗 |
| 交换目录 | `C:\Users\Public\wsl-desktop-clip\` | `win.txt`（Windows 剪贴板快照）、`linux.req.txt`（要写回 Windows 的文本）、`agent.heartbeat`（代理心跳）、`agent.log` |
| `clipbridge` | WSL 用户服务 `wsl-clipbridge` | 把内层 GNOME（Wayland）剪贴板 ⇄ 交换目录同步 |

- 双向、**纯文本**、延迟约 0.5~2 秒；图片/文件不支持
- 不需要 `xclip`、不经过 WSLg 的 RDP 剪贴板通道，WSLg 剪贴板卡死也不影响
- 代理用 `OpenClipboard/GetClipboardData/SetClipboardData` 直接操作，**不会因为别的程序占着剪贴板而卡死**（那正是旧版 PowerShell `Get-Clipboard` 卡住的原因）

安装 / 更新（可重复执行）：

```bash
# 1) root 安装桥脚本 + 代理脚本 + 用户级 systemd 服务
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/install-clipbridge.sh

# 2) 普通用户启用并启动服务
bash ~/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/enable-clipbridge.sh
```

日常使用与检查：

```bash
~/start-desktop.sh --check                 # 看「剪贴板代理(Windows): 在跑」「剪贴板桥(服务): active」
tail -n 20 /tmp/clipbridge.log             # 桥的同步记录（双向都记）
cat /mnt/c/Users/Public/wsl-desktop-clip/agent.log   # 代理日志（Windows 侧，双向都记）
bash ~/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/final-clip-test.sh   # 双向自测
```

> Windows 侧代理也可以手动启动（桌面启动脚本没跑时）：
> ```powershell
> powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\wsl-desktop-clip\clip-agent.ps1
> ```

> Ubuntu 26.04 自带 **uutils coreutils 0.10.0**（Rust 版）：老式 `tail -20 文件` 必须带空格，写成 `tail -20/tmp/...` 会报 `tail: option used in invalid context -- 2`。建议一律用 `tail -n 20 文件`。

## 声音（路线 A 实测 2026-11-12）

WSLg 自带音频服务（`RDPSink` → Windows 默认扬声器）。嵌套桌面要出声，关键只有一条：让会话里的应用连上 WSLg 的 PulseAudio：

- `~/start-desktop.sh` 导出并写入 `PULSE_SERVER=unix:/mnt/wslg/PulseServer`
- `org.gnome.Shell@.service` 的 override 里也加了同样的 `Environment=`
- `~/.config/environment.d/pulse.conf` 让 dbus 激活的应用也能拿到

安装（已经配好的机器可跳过，脚本可重复执行）：

```bash
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/audio/install-audio.sh   # root：写 override / environment.d / start-desktop.sh
bash ~/wsl2-nested-gnome-desktop/wsl-desktop/audio/restart-desktop.sh      # 普通用户：重启桌面会话并自检
```

自检（应看到 `Default Sink: RDPSink`）：

```bash
PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl info | grep -E 'Default Sink|Default Source'
PULSE_SERVER=unix:/mnt/wslg/PulseServer paplay /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga
```

**已知坑（本机 WSLg 1.0.79 实测，不稳定）**：WSLg 的音频链路会周期性卡死——`/mnt/wslg/pulseaudio.log` 刷 `asyncq.c: q overrun, queuing locally`，socket 不再接受连接，于是 GNOME 里显示「无输出设备」。这是 WSLg 的 bug，不是 GNOME 配置问题。打开「设置 > 声音」面板、播放提示音、某些播放/暂停操作都可能触发。

2026-11-12 实测确认的**正确恢复方式**：

- 热重启 WSLg 的 PulseAudio：`wsl --system -- sh -c "pkill -9 pulseaudio"`，WSLGd 会立即拉起新实例；Weston 的播放线程会自动重连（`weston.log` 里出现一次 `Audio sink thread: error while reading from sink socket` 属正常）。**实测约 3 秒恢复，不需要重启 WSL**。
- `~/start-desktop.sh` 每次启动都会做这件事（自检 → 卡死就热重启 → 确认 `Default Sink: RDPSink`），所以「启动时没声音」只要重新跑一次脚本即可；桌面已在运行也不会重复启动。
- Windows 侧剪贴板代理 `clip-agent.ps1` 自带音频看门狗：每 20 秒检测一次，卡死会自动关面板 + 热重启，日志在 `C:\Users\Public\wsl-desktop-clip\agent.log`。旧的 `audio/audio-watchdog.ps1` 保留仅作参考。
- 已做的缓解：`start-desktop.sh` 会关掉系统提示音（`event-sounds=false`、`input-feedback-sounds=false`）并给会话写入 `PULSE_SERVER`。
- **snap 应用（Firefox/Thunderbird）的音频**：snapd 会把它们的 `PULSE_SERVER` 固定成 `$XDG_RUNTIME_DIR/pulse/native`，原本连到会话里 pipewire-pulse 的哑设备「虚拟输出」→ 浏览器没声音。已屏蔽 pipewire-pulse，并用系统服务 `wslg-pulse-bind.service` 把 WSLg 的 `PulseServer` **bind mount** 到 `/run/user/1000/pulse/native`，snap 应用即可直接连上 WSLg 音频；PulseAudio 热重启换 inode 后该守护会自动重挂。
- 诊断：`audio/audio-watch.sh` 每 5 秒记录音频状态到 `/tmp/audio-watch.log`；`~/start-desktop.sh --check` 直接看「声音服务 / 默认输出 / pulse socket 挂载」三行。
- **实测（2026-11-12 17:03–17:12）**：桌面从 `systemd-run` 启动后音频自动恢复正常；播放 6 秒测试音耗时 6104 ms（≈实时消费，说明 RDP 音频链路通）；热重启后 socket 自动重挂（同 inode）。
- 已知限制：WSLg 音频仍可能在播放/暂停后周期性卡死，属 WSLg 1.0.79 的 bug；看门狗可自动恢复，需要「绝对稳定音频」建议改用 RDP 桌面方案。
- 桌面窗口（`Mutter Development Kit`）就是桌面本体：**关掉窗口 = 退出桌面**，重开用 `audio/restart-desktop.sh` 或下面的一行命令。
- 想调音量用键盘音量键即可（`gsd-media-keys` 已连上 WSLg 音频）。
- 桌面会话用 systemd 用户单元 `wsl-desktop-session.service` 托管（`systemd-run --user` 启动），关掉终端也不会退出。

## 会话管理：启动 / 停止 / 重启（含 “A graphical session is already running!”）

桌面窗口被关掉后，GNOME 的会话管理器可能残留，此时再运行 `~/start-desktop.sh` 会报：

```
** (process:xxxxx): ERROR **: A graphical session is already running!
```

现在 `~/start-desktop.sh` 会自动处理：检测到残留会话 → 先 `gnome-session-quit` 正常注销 + 兜底清理，再启动；如果桌面本来就在跑，只提示、不再报错退出。

2026-11-12 起，`~/start-desktop.sh` 默认是**后台启动**：把桌面交给 `systemd-run --user` 托管后立即返回，**不会占用当前终端**。

```bash
~/start-desktop.sh                # 后台启动（立即返回，不占终端；幂等，可重复执行）
~/start-desktop.sh --check        # 只看状态（会话/声音/剪贴板；含「会话状态：正常/残留/未运行」）
~/start-desktop.sh --fix          # 只修声音/剪贴板（不启动桌面）
~/start-desktop.sh --stop         # 停止桌面（等价 ~/stop-desktop.sh）
~/start-desktop.sh --foreground   # 前台启动（会占用终端，调试/排障用）

# 旧的 systemd-run 写法仍然兼容（脚本检测到在 systemd 单元里就不再套一层）；
# 但单元已存在时（桌面在跑，或上次关窗口后残留）它会报 already loaded，属正常，日常请用第一行
systemd-run --user --unit=wsl-desktop-session --collect ~/start-desktop.sh

# 重启桌面
~/start-desktop.sh --stop && ~/start-desktop.sh
```

从桌面里启动的应用窗口会留在「Mutter Development Kit」桌面窗口内部（嵌套 Wayland），
不会变成 Windows 任务栏上单独的「计算器 (Ubuntu)」「软件更新器 (Ubuntu)」窗口。
`--check` 里对应「应用窗口归属: 在 Ubuntu 桌面窗口内（嵌套 Wayland）」。
如果显示「可能跑到 Windows 外层」（例如 apt 升级过 mutter），跑一次 `~/start-desktop.sh --fix`
再重启桌面即可自愈；原理见 `TROUBLESHOOTING.md` 4.9（纯 X11 应用除外）。

Windows 里也有对应的一键脚本（后台启动、立即返回；在仓库任意目录双击 `start-desktop.cmd` 也可以）：

```powershell
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1            # 启动
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Status    # 查看状态
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Stop      # 停止

# 完全不依赖路径（Windows 任意目录可用）：
wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"
```

## 路线 B：Ubuntu 24.04 + Xwayland 教程（要登录界面选这个）

前提：WSL2 + WSLg、systemd、约 6~8 GB 磁盘（装完整 ubuntu-desktop）。

```powershell
# 1) 安装 Ubuntu 24.04
wsl --install -d Ubuntu-24.04

# 2) 首次打开创建用户后，在 Ubuntu 终端里：
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2404-xwayland.sh --yes --resolution 1920x1080

# 3) 重启 WSL
wsl.exe --shutdown

# 4) 重新打开 Ubuntu 24.04 终端，启动图形
sudo systemctl start graphical.target
```

- 分辨率同时写入 Xwayland 和 `monitors.xml`，可用 `--resolution 2560x1440` 等；
- 想开机自动进图形（可选，评论反馈可行）：`sudo systemctl enable graphical.target`；
- 退出桌面必须走「关机」菜单或 `sudo poweroff`，**等 WSL 结束后**再 `wsl --shutdown`。

## 回滚

```bash
# 路线 A
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2604.sh --rollback

# 路线 B（会尝试恢复 /usr/bin/Xorg、gnome-session、默认 target 等）
sudo bash ~/wsl2-nested-gnome-desktop/wsl-desktop/wsl-desktop-2404-xwayland.sh --rollback
```

最干净的回滚永远是：`wsl --export` 备份后 `wsl --unregister` 重建。安装桌面元包会拉入大量依赖，手动卸载很难恢复原样。

## 必须知道的限制

- **路线 A 是社区方案**（来源：tdcosta100 gist 评论区 2026-08），作者未合并进正文，脚本作者也未在真机验证；GNOME/WSL 升级后可能失效。
- 路线 A：没有登录界面（除非用 RDP）、分辨率/全屏受限；剪贴板原本只有「Linux → Windows」原生通，反向由 `clipboard/` 的 `clipbridge` 补上（仅文本）；声音链路可用但**播放声音会卡死 WSLg 音频服务**（本机实测），不建议依赖，需要声音请走 RDP 方案；部分应用仍会以独立 WSLg 窗口打开。
- 路线 B：侵入性强（替换系统 Xorg、改 gnome-session），教程作者也建议出问题时直接重建发行版；系统升级可能覆盖改动。
- 两条路线都需要 `/etc/wsl.conf` 里 `[boot] systemd=true`；脚本检测到未开启时会自动写入并提示你 `wsl --shutdown` 后重跑。
- 请先 `wsl --export` 备份，最好在独立、可丢弃的实例上实验。

## 脚本做了什么（概要）

**路线 A（26.04）**
1. `apt-get update`
2. 安装 `ubuntu-desktop`（默认 `--no-install-recommends`，`--full` 安装完整版）
3. 安装 `snap-store`（可选，失败忽略）
4. 安装 `mutter-dev-bin`
5. 写 `/etc/systemd/user/org.gnome.Shell@.service.d/override.conf`：
   `ExecStart=/usr/bin/gnome-shell --devkit --no-x11 --mode=%i`
6. 生成 `~/start-desktop.sh`（以普通用户身份启动 `gnome-session`）

**路线 B（24.04）**：按原教程逐条执行——装 `ubuntu-desktop` + `xwayland`；建 `wslg-fix.service`；mask `wslg-session`；给 `gnome-session` 加 `--disable-acceleration-check`；`set-default multi-user.target`；安装 `/usr/bin/Xorg.Xwayland`；`dpkg-divert` + `update-alternatives` 替换 Xorg；写 `monitors.xml` 并复制给 GDM（`--rollback` 反向恢复）。

## 来源

- Xwayland 教程：<https://gist.github.com/tdcosta100/e28636c216515ca88d1f2e7a2e188912>
- Wayland 教程（26.04 配方来自评论区）：<https://gist.github.com/tdcosta100/7def60bccc8ae32cf9cacb41064b1c0f>
- GNOME 50 移除 X11：<https://itsfoss.com/news/gnome-50-release/>
- Ubuntu 26.04 发布信息：<https://www.cnx-software.com/2026/04/24/ubuntu-26-04-lts-resolute-raccoon-released-with-linux-7-0/>
