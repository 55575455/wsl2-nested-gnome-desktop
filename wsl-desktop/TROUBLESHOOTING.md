# WSL2 嵌套 GNOME 桌面 · 故障排除指南（全程复制粘贴）

> 适用：Windows 10/11 + WSL2 + WSLg + **Ubuntu 26.04 / Fedora 45 / Kali 2026 / Oracle Linux 10 / Debian testing**
> 本指南假设你**不会 Linux，也不想学**——只需要复制命令、粘贴、回车。
> 开源分享版（公开仓库）

---

## 📖 目录

0. [公开仓库（脱敏版）用户：先填自己的路径](#0-公开仓库脱敏版用户先填自己的路径)
1. [先看这里：5 个一键脚本](#1-先看这里5-个一键脚本)
2. [怎么复制粘贴（Windows / WSL 操作区分）](#2-怎么复制粘贴windows--wsl-操作区分)
3. [一键自检（先跑这个）](#3-一键自检先跑这个)
4. [桌面问题](#4-桌面问题)
   - 4.1 桌面窗口完全不出来
   - 4.2 启动报 “A graphical session is already running!”
   - 4.3 关掉桌面窗口后想重新打开
   - 4.4 桌面黑屏/卡死/花屏
   - 4.5 启动报错：`-File ... 不存在` / `Unit ... was already loaded`
   - 4.6 反复弹出「需要认证」（flatpak 系统级安装）
   - 4.7 任务栏图标反复闪烁 / 「警告：Desktop Icons NG 正在 X11Wayland 下运行」
   - 4.8 任务栏齿轮图标反复闪（剪贴板桥轮询 wl-paste 引起）
   - 4.9 从 Ubuntu 桌面启动的应用“跳出桌面”，变成 Windows 上单独的窗口
   - 4.10 其他发行版（Fedora / Kali / Oracle Linux）桌面起不来 / 应用跑出去
   - 4.11 把桌面语言改成中文（或改回英文）
5. [声音问题](#5-声音问题)
   - 5.1 先分清是哪种“没声音”
   - 5.2 设置里显示“无输出设备”（音频服务卡死）
   - 5.3 有设备、但没声音
   - 5.4 浏览器（Firefox/Thunderbird）没声音
   - 5.5 声音断续/卡顿
   - 5.6 什么时候需要重启整个 WSL
6. [剪贴板问题](#6-剪贴板问题)
7. [一键收集诊断信息（发给我/发 issue 用）](#7-一键收集诊断信息发给我发-issue-用)
8. [完全重装 / 回滚](#8-完全重装--回滚)
9. [命令速查表](#9-命令速查表)
10. [常见英文报错对照表](#10-常见英文报错对照表)

---

## 0. 公开仓库（脱敏版）用户：先填自己的路径

> ⚠️ 公开仓库里的文档/脚本是**脱敏版**：个人路径都被换成了占位符，例如
> `C:\Users\<用户名>`、`/home/<用户名>`、`<用户名>@<主机名>`、`~/wsl2-nested-gnome-desktop`。
> **必须替换成你本机的实际路径**，否则命令里的路径不存在，安装/启动会失败。

**做法（在仓库根目录，Windows PowerShell）：**

```powershell
# 1) 查看本机实际路径 + 列出所有含占位符的脱敏文件位置 + 对照表
powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1

# 2) 确认后自动替换（会修改文档/脚本，建议先 git status）
powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1 -Apply
```

如果仓库只在 WSL 里，也可以用 WSL 版（功能相同）：

```bash
bash ~/wsl2-nested-gnome-desktop/oneclick/show-paths.sh          # 查看
bash ~/wsl2-nested-gnome-desktop/oneclick/show-paths.sh --apply  # 自动替换
```

脚本会给出你的实际值（照着填即可）：

| 占位符 | 你会看到的实际值 |
|---|---|
| `C:\Users\<用户名>` | `C:\Users\你的Windows用户名` |
| `/home/<用户名>` | `/home/你的WSL用户名` |
| `<用户名>@<主机名>` | `你的WSL用户名@你的主机名` |
| `~/wsl2-nested-gnome-desktop` | 你仓库在 WSL 里的实际路径 |

不想自动替换就按脚本打印的对照表手动改（脚本会列出**每个含占位符的文件相对路径和绝对路径**，即「脱敏文件位置」清单）。

---

## 1. 先看这里：5 个一键脚本

仓库里 `oneclick/` 目录（**把内容整段复制给朋友即可，不需要对方会 Linux**）：

| 脚本 | 用途 | 怎么用 |
|---|---|---|
| `oneclick/show-paths.ps1` | **公开仓库必读**：显示本机实际路径、列出所有含占位符的脱敏文件，`-Apply` 自动填写 | 在 Windows PowerShell 里运行 |
| `oneclick/install.ps1` | **一键安装**：检查 WSLg、装桌面、配剪贴板、配声音、启动桌面 | 在 Windows PowerShell 里运行 |
| `oneclick/start-desktop.ps1` | **一键启动桌面（后台运行，立即返回，不占用终端）**；`-Status` 看状态、`-Stop` 停止、`-FixOnly` 只修声音/剪贴板、`-Wait` 等窗口出现 | 在 Windows PowerShell 里运行（或双击 `start-desktop.cmd`） |
| `oneclick/fix-audio.ps1` | **一键修声音**：先让 `~/start-desktop.sh --fix` 自检并热重启音频，必要时再重启 WSL、重开桌面 | 在 Windows PowerShell 里运行 |
| `oneclick/restart-desktop.ps1` | **一键重开桌面**：清理残留会话 + 重新启动桌面窗口（同时会修声音/剪贴板） | 在 Windows PowerShell 里运行 |

运行方式（复制 → 粘贴 → 回车）：

```powershell
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\show-paths.ps1"       # 公开仓库必读：先填自己的路径
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\install.ps1"
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\start-desktop.ps1"     # 以后启动桌面（不占终端）
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\fix-audio.ps1"
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\restart-desktop.ps1"
```

> 💡 **2026-11-12 起**：`~/start-desktop.sh` 默认**后台启动**（桌面交给 systemd 用户单元，脚本立即返回，**终端不会被占用**）。
> 它每次运行都会：① 音频卡死就热重启 WSLg 的 PulseAudio；② 拉起 Windows 侧剪贴板代理；③ 启动剪贴板桥。
> 「没声音 / 没剪贴板」→ `~/start-desktop.sh --fix`（只修，不启动桌面）；需要前台看日志才用 `--foreground`。
>
> ⚠️ 上面的 `.\oneclick\...` 写法要求**当前目录就是仓库根目录**。如果你在 `C:\windows\System32`
> 等其它目录，请用完整路径（`"C:\你的路径\oneclick\start-desktop.ps1"`），或**双击** `oneclick\start-desktop.cmd`
> （自动定位脚本），或完全不依赖目录的一条命令：
>
> ```powershell
> wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"      # 启动（幂等，立即返回）
> ```
>
> 启动时如果看到 `Unit wsl-desktop-session.service was already loaded`，说明桌面单元已存在（不是错误），
> 用上面的 `~/start-desktop.sh` 即可自动清理残留单元（详见 4.5 节）。

> 没有仓库文件？见 [第 1.1 节：把脚本发给别人](#11-把脚本发给别人)。

### 1.1 把脚本发给别人

因为仓库是私有的，最省事的方式：

1. 用记事本打开 `oneclick/install.ps1`，**全选 → 复制**；
2. 发给对方（微信/QQ/邮件都行）；
3. 对方粘贴到一个新文件 `install.ps1` 里保存；
4. 对方右键“使用 PowerShell 运行”，或在 PowerShell 里执行
   `powershell -ExecutionPolicy Bypass -File .\install.ps1`。

脚本里已经**内嵌了全部需要的内容**，对方不需要下载仓库、不需要懂 Linux。

### 1.2 其他发行版（Fedora / Kali / Oracle Linux / Debian）

`install.ps1` 会自动识别 apt / dnf，并按发行版安装：

```powershell
# 只装某一个发行版（名字用 wsl -l -v 查看）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro FedoraLinux-45
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro kali-linux
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro oracle-linux-10

# 所有已安装的发行版都装一遍（逐个安装，最后汇总）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -All

# 已经装过桌面组件，只更新脚本/配置（不重复下载）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro FedoraLinux-45 -SkipPackages
```

启动/状态/修复也带 `-Distro`：

```powershell
powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Distro FedoraLinux-45
powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1 -Distro oracle-linux-10 -Status
powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1 -Distro kali-linux
```

各发行版的差异（`install.ps1` 会自动处理）：

| 发行版 | 桌面组件 | 桌面模式 | 窗口标题 |
|---|---|---|---|
| Ubuntu 26.04 | `ubuntu-desktop` + `mutter-dev-bin` | devkit（GNOME 50） | `Mutter Development Kit (Ubuntu)` |
| Fedora 45 | `gnome-shell` + `mutter-devkit` | devkit（GNOME 51） | `Mutter Development Kit (FedoraLinux-45)` |
| Kali 2026 | 最小 GNOME 集合 + `mutter-dev-bin` | devkit（GNOME 50） | `Mutter Development Kit (kali-linux)` |
| Debian testing | 最小 GNOME 集合 + `mutter-dev-bin` | devkit（GNOME 51） | `Mutter Development Kit (Debian)` |
| Oracle Linux 10 | `gnome-shell-47` + `mutter-47`（RHEL 没有 devkit） | **nested**（GNOME 47 的 `--nested`） | `gnome-shell (oracle-linux-10)` |

> Oracle Linux 10 的 WSL 镜像默认**没开 systemd、没有普通用户、没配 AppStream 仓库**。
> `install.ps1` 会写好 `/etc/wsl.conf` 并自动 `wsl --terminate` 后重试，第一次安装会多花一两分钟。
>
> 同时开**多个发行版桌面**时，剪贴板会互相抢（它们共用 Windows 侧的同一个交换目录）——
> 建议一次只开一个桌面（见第 6 章 ⑤）。

---

## 2. 怎么复制粘贴（Windows / WSL 操作区分）

| 位置 | 怎么打开 | 提示符长什么样 |
|---|---|---|
| **Windows PowerShell** | 开始菜单搜“PowerShell” | `PS C:\Users\你>` |
| **WSL（Ubuntu 终端）** | 开始菜单搜“Ubuntu” | `u@主机名:~$` |

⚠️ 本指南的代码块会标注 `[Windows]` 或 `[WSL]`，**别贴错窗口**。

粘贴到 WSL 终端用 **`Ctrl+Shift+V`**（或鼠标右键）；粘贴到 PowerShell 用 **`Ctrl+V`** 或右键。

---

## 3. 一键自检（先跑这个）

### 3.1 [Windows] 基础检查

```powershell
wsl --version
wsl -l -v
wsl -d Ubuntu -- bash -lc "echo DISPLAY=$DISPLAY; ls /mnt/wslg/PulseServer 2>/dev/null; ls /mnt/wslg/.X11-unix/X0 2>/dev/null"
```

期望：`DISPLAY=:0`、两个 socket 都有输出。
若 `DISPLAY=` 是空的 → 看 [4.1](#41-桌面窗口完全不出来)。

### 3.2 [WSL] 桌面 / 服务检查

```bash
~/start-desktop.sh --check
echo "--- 桌面进程 ---"
pgrep -a -x gnome-shell || echo "(没有 gnome-shell)"
echo "--- 声音 ---"
PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C timeout 5 pactl info 2>&1 | grep -E "Default Sink|Default Source" || echo "(音频服务卡死)"
echo "--- 剪贴板 ---"
systemctl --user is-active wsl-clipbridge
ls -l /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat 2>/dev/null || echo "(剪贴板代理没在跑)"
echo "--- 会话 pulse socket（snap 应用用）---"
mountpoint /run/user/1000/pulse/native 2>&1
```

把输出对照下面的表格：

| 现象 | 看哪一节 |
|---|---|
| 没有 gnome-shell | [4.2](#42-启动报-a-graphical-session-is-already-running) / [4.3](#43-关掉桌面窗口后想重新打开) |
| 音频服务卡死（FAIL） | [5.2](#52-设置里显示无输出设备音频服务卡死) |
| 音频正常但听不到 | [5.3](#53-有设备但没声音) |
| 浏览器没声 | [5.4](#54-浏览器firefoxthunderbird没声音) |
| 剪贴板不通 | [6](#6-剪贴板问题) |

---

## 4. 桌面问题

### 4.1 桌面窗口完全不出来

**先查这几个（[WSL]）：**

```bash
echo "DISPLAY=$DISPLAY"
ls /mnt/wslg
ls /mnt/wslg/.X11-unix/ 2>/dev/null
cat /etc/wsl.conf
systemctl --user status 'org.gnome.Shell@ubuntu.service' --no-pager | head -20
```

**如果 `DISPLAY` 为空 / `/mnt/wslg` 是空的** → WSLg 没启用：

1. 打开 `C:\Users\你的用户名\.wslconfig`（没有就新建），确保有：

   ```ini
   [wsl2]
   guiApplications=true
   ```

2. [Windows] 执行：

   ```powershell
   wsl --shutdown
   ```

3. 重新打开 Ubuntu 终端，再跑 `~/start-desktop.sh`。

**如果 `DISPLAY` 正常但还是没窗口**：检查 `/etc/systemd/user/org.gnome.Shell@.service.d/override.conf`
是否包含 `GDK_BACKEND=x11`、`DISPLAY=:0`（一键安装脚本会自动写）。

### 4.2 启动报 “A graphical session is already running!”

**现象**（你看到的就是这个）：

```
** (process:xxxxx): ERROR **: A graphical session is already running!
已中止
```

**原因**：上次关桌面窗口时 gnome-shell 退了，但 GNOME 的“会话管理器”没退干净，
新的会话被判定为“已有图形会话”。

**处理（新版本已自动处理，直接重跑即可）**：

```bash
~/start-desktop.sh
```

如果还报错，先手动清理再启动：

```bash
~/stop-desktop.sh
~/start-desktop.sh
```

`~/start-desktop.sh --check` 可以看状态：

```
gnome-shell:            0 个
gnome-session target:   inactive
SessionManager DBus:    空闲
wayland socket:         无
```

### 4.3 关掉桌面窗口后想重新打开

桌面窗口（标题 **Mutter Development Kit**）就是桌面本体，**关掉它 = 关掉桌面**，这是正常的。

重新打开（推荐，Windows 任意目录都能用这一条，立即返回）：

```powershell
wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"
```

```bash
# [WSL] 等价写法
~/start-desktop.sh
```

> ⚠️ 不要反复手动粘贴 `systemd-run --user --unit=wsl-desktop-session ...` 原命令：
> 单元已经存在（桌面在跑，或上次关窗口后没退干净）时，它会报
> `Unit wsl-desktop-session.service was already loaded or has a fragment file`。
> **这不是错误**，说明桌面单元已存在；日常统一用 `~/start-desktop.sh`
> （幂等、会自动清理残留单元，见 4.5 节）。

重启（先停后开）：

```bash
~/start-desktop.sh --stop && ~/start-desktop.sh
```

### 4.4 桌面黑屏 / 卡死 / 花屏

1. 先尝试重开：

   ```bash
   ~/start-desktop.sh --stop
   ~/start-desktop.sh
   ```

2. 还不正常 → [Windows] 重启 WSL：

   ```powershell
   wsl --shutdown
   ```

   然后重新打开 Ubuntu 终端，执行：

   ```bash
   ~/start-desktop.sh
   ```

3. 仍然黑屏：运行一键脚本 `oneclick/restart-desktop.ps1`。

### 4.5 启动报错：`-File ... 不存在` / `Unit ... was already loaded`

**① PowerShell 报 `-File 形式参数的实际参数“.\oneclick\start-desktop.ps1”不存在`**

含义：当前 PowerShell 所在目录不是仓库根目录（从开始菜单打开时默认在 `C:\windows\System32`），
`.\oneclick\...` 这种相对路径自然找不到文件。三种解法（任选）：

```powershell
# 1) 先进入仓库目录，再运行
cd C:\Users\<用户名>\Desktop\wsl2-nested-gnome-desktop
powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1

# 2) 用完整路径（不需要 cd）
powershell -ExecutionPolicy Bypass -File "C:\Users\<用户名>\Desktop\wsl2-nested-gnome-desktop\oneclick\start-desktop.ps1"

# 3) 一条不依赖目录的命令（推荐，Windows 任意位置都能用）
wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"
```

> 最简单的办法：在资源管理器里**双击** `oneclick\start-desktop.cmd`
> ——它用 `%~dp0` 自动定位同目录的 `start-desktop.ps1`，和当前目录无关。

**② 报 `Failed to start transient service unit: Unit wsl-desktop-session.service was already loaded or has a fragment file.`**

含义：`systemd-run` 的单元名已被占用——**桌面已经在运行**，或者**上次关窗口后单元残留**（很常见）。
**这不是错误，不用杀进程、也不用重启 WSL。**

```bash
~/start-desktop.sh --check    # 看「会话状态」：正常 / 残留（unit 在跑但桌面已退出）/ 未运行
~/start-desktop.sh            # 幂等启动：已运行只检查；残留会自动清理再启动；立即返回
~/start-desktop.sh --stop     # 实在不行：先停掉再启动
```

> 日常不要再手动执行 `systemd-run ...` 原命令（它只适合“单元不存在”的首次启动，重复执行必然报 already loaded）。
> 约定：**启动桌面一律用 `~/start-desktop.sh`**（Windows 侧用 `oneclick\start-desktop.ps1`，或双击 `start-desktop.cmd`）。

### 4.6 反复弹出「需要认证」（flatpak 系统级安装）

**现象**：桌面正中间反复弹出一个白底窗口，标题「需要认证」，下面英文写着
`Authentication is required to modify a system repository`，要你输入密码。

**原因**：**不是桌面 / 本项目的问题**——是 Flatpak 在做“系统级安装/更新”。
`flatpak install flathub <应用ID>` 不带 `--user` 时默认装到**系统仓库**，每修改一次系统仓库
都要通过 polkit 请求管理员授权，所以会（反复）弹窗；装到一半网络失败重试时还会再弹。

**处理（三选一）**：

1. **不想装 / 想马上停**：在跑 flatpak 的那个终端窗口里按 `Ctrl+C`；
   找不到终端就直接结束进程（弹窗会自动消失）：
   ```bash
   pkill -f "flatpak install"
   ```
2. **想装但不要再被弹窗打扰**：安装到当前用户（不需要密码、不需要授权）：
   ```bash
   flatpak install --user flathub <应用ID>
   ```
3. **就是要系统级安装**：在弹窗里输入密码点「认证」一次，然后继续；
   如果下载失败后重试，可能会再弹一次。

> 如果你根本没在装 flatpak 却反复看到这个弹窗：在终端里执行 `ps -ef | grep flatpak`
> 看是哪个命令在跑，把它结束即可。本项目的脚本（启动/声音/剪贴板）都不会触发这个弹窗。

### 4.7 任务栏图标反复闪烁 / 「警告：Desktop Icons NG 正在 X11Wayland 下运行」

**现象**：任务栏（dock）里一个齿轮图标每隔一两秒闪出来又消失；过一会儿弹出白底「警告」窗口，内容：

- `Desktop Icons NG 正在 X11Wayland 下运行`
- `您的系统似乎被配置为强制 GTK 使用 X11。…`

**原因**（本项目嵌套桌面的特有情况，和 Flatpak/安装无关）：

- 为了让 `mutter-devkit` 的桌面窗口出现在 WSLg 里，`gnome-shell` 的 systemd override 必须带
  `GDK_BACKEND=x11` + `DISPLAY=:0`（见 `wsl-desktop/audio/install-audio.sh`）；
- 这个环境会被所有 GTK 子进程继承，**Ubuntu 的桌面图标扩展（ding）** 因此以 X11Wayland 运行；
- 嵌套会话是 `--no-x11` 的，ding 的桌面窗口会被反复重建 → 每次都重新弹这个警告，
  任务栏图标也跟着闪（`journal` 里还会刷 `meta_window_set_stack_position_no_sync` 断言）。

**处理**（`~/start-desktop.sh` 已自动做，无需手动）：

```bash
# 1) 关掉 ding 的 X11Wayland 检查（不再弹警告）
gsettings set org.gnome.shell.extensions.ding check-x11wayland false

# 2) 更彻底：禁用桌面图标扩展（嵌套桌面不需要桌面图标；启动脚本默认禁用）
gnome-extensions disable ding@rastersoft.com
```

查看状态：

```bash
~/start-desktop.sh --check      # 最后一行「桌面图标扩展(ding): 已禁用（防闪烁）」
```

想恢复桌面图标：`gnome-extensions enable ding@rastersoft.com`
（警告不会再弹，但任务栏图标闪烁可能回来）。

### 4.8 任务栏齿轮图标反复闪（剪贴板旧方案的 wl-paste 轮询引起）

**现象**：dock 里一个灰色齿轮图标（左侧带橙色“运行”点）每隔 1~2 秒闪出来又消失，像有窗口反复弹出；
和 4.7 的「警告」弹窗是两回事。

**原因**：旧版剪贴板桥 `wsl-clipbridge` 为了同步「内层 Linux → Windows」剪贴板，会定期运行 `wl-paste`；
而 **`wl-paste`（wl-clipboard）每次运行都会创建一个临时窗口**（标题 `wl-clipboard`），
Ubuntu Dock 把它当成“未知应用”画出齿轮图标——桥轮询多快，图标就闪多快，还会抢焦点
（**是本项目的剪贴板桥，不是系统服务**）。

**现在的处理**（`~/start-desktop.sh` 已自动做，Dock 的“运行中程序”图标**保留**）：

剪贴板同步改为 **GNOME Shell 扩展** `clipbridge@wsl-desktop`（安装在
`/usr/share/gnome-shell/extensions/clipbridge@wsl-desktop/`，源码在 `wsl-desktop/clipboard/extension/`）：
在 gnome-shell 进程内部直接读/写剪贴板（compositor 上下文），**完全不需要窗口、不抢焦点**，
所以不会再出现这个齿轮图标；`wsl-clipbridge` 服务只在后台保活（不再轮询 `wl-paste`）。

查看当前用的哪种方式：

```bash
~/start-desktop.sh --check
# 桌面图标扩展(ding):     已禁用（防闪烁）
# Dock 运行图标:          已开启（保留运行图标，方便切换）
# 剪贴板同步:             GNOME Shell 扩展（无窗口、不抢焦点）
```

如果显示「wl-paste 轮询（旧方式，会闪 Dock 图标）」：说明 shell 扩展没装或没启用，
重跑安装脚本 / `~/start-desktop.sh --fix`，或手动启用：

```bash
gnome-extensions enable clipbridge@wsl-desktop
```

> 想临时回到“关掉运行图标”的规避方式（一般不需要，扩展方案已兼顾运行图标和剪贴板）：
> `gsettings set org.gnome.shell.extensions.dash-to-dock show-running false`

### 4.9 从 Ubuntu 桌面启动的应用“跳出桌面”，变成 Windows 上单独的窗口

**现象**：

- 在 Ubuntu 桌面（「Mutter Development Kit」窗口）里点应用，窗口却出现在 Windows 上：
  任务栏里多出一个按钮，悬停预览写着「计算器 (Ubuntu)」「软件更新器 (Ubuntu)」这类标题；
- Ubuntu 桌面里看不到这个窗口（或者它浮在桌面窗口上面，但不属于桌面，切换桌面时仍留在 Windows 上）；
- 这类窗口有时还会“叠”在桌面上，看起来像“应用会额外开窗口”。

**原因**（本项目早期配置的问题，不是应用 bug）：

- 为了让「Mutter Development Kit」桌面窗口出现在 WSLg 里，`gnome-shell` 的 systemd override
  以前设置了 `GDK_BACKEND=x11` + `DISPLAY=:0`；
- gnome-shell 启动应用时会把**自己的环境变量**传给子进程，于是所有 GTK 应用都被强制走 X11，
  连到 WSLg 外层的 Xwayland `:0` → 窗口就跑到 Ubuntu 桌面外面，变成 Windows 上单独的窗口；
- 通过 D-Bus 激活的应用（例如日历）不继承 shell 的环境，所以它们看起来一直是正常的。

**现在的处理**（安装脚本 + `~/start-desktop.sh` 自动做，apt 升级后也会自愈）：

1. `gnome-shell` 的 systemd override 去掉 `GDK_BACKEND=x11`，只保留
   `DISPLAY=:0`、`WAYLAND_DISPLAY=wayland-1`、`PULSE_SERVER`；
2. 只负责“桌面窗口”的 `mutter-devkit` 改用包装脚本 `/usr/libexec/mutter-devkit` 单独强制 X11，
   原版二进制保留为 `/usr/libexec/mutter-devkit.real`；
3. 这样 gnome-shell 启动的应用会走**嵌套 Wayland 桌面**（`wayland-1`），
   snap 应用（Firefox / 软件中心）也能通过 `WAYLAND_DISPLAY` 正确进入桌面。

**验证**（Windows 任务栏里应该只有一个 Ubuntu 桌面窗口）：

```bash
~/start-desktop.sh --check
# 应用窗口归属:           在桌面窗口内（嵌套 Wayland，devkit 模式）
```

- 显示「在桌面窗口内」= 正常；
- 显示「可能跑到 Windows 外层」= 配置被还原（例如 apt 升级了 mutter），先跑（不会重启桌面）：

```bash
~/start-desktop.sh --fix
```

  再重启桌面生效：`~/start-desktop.sh --stop && ~/start-desktop.sh`
- 也可以在 Windows 任务栏确认：只剩「Mutter Development Kit (发行版)」，没有单独的
  「计算器 (Ubuntu)」「软件更新器 (Ubuntu)」窗口。

**限制**：

- 支持 Wayland 应用（GNOME/GTK、Qt、snap、Flatpak 等绝大多数）以及 D-Bus 激活的应用；
- **纯 X11 应用**（少数老程序、部分 Java/Electron 程序）在这个嵌套会话里没有自己的 X 服务器，
  仍会跑到 Windows 外层。可以优先用它的 Wayland 模式（例如 `--ozone-platform=wayland`），
  或者接受它作为单独窗口显示。

**恢复默认（回到“应用跑出去”的旧行为，一般不需要）**：

```bash
# Windows PowerShell
wsl -d Ubuntu -u root -- bash -lc "sed -i '/^Environment=WAYLAND_DISPLAY=wayland-1/d; s/^Environment=DISPLAY=:0$/Environment=GDK_BACKEND=x11\nEnvironment=DISPLAY=:0/' /etc/systemd/user/org.gnome.Shell@.service.d/override.conf; mv -f /usr/libexec/mutter-devkit.real /usr/libexec/mutter-devkit"
```

然后在 WSL 里重启桌面：`~/start-desktop.sh --stop && ~/start-desktop.sh`。

### 4.10 其他发行版（Fedora / Kali / Oracle Linux）桌面起不来 / 应用跑出去

**先看模式**（所有发行版通用）：

```bash
~/start-desktop.sh --check
```

| 看到什么 | 正常吗 |
|---|---|
| `桌面模式: devkit`，`SessionManager DBus: 已占用` | 正常（Ubuntu / Fedora / Kali） |
| `桌面模式: nested`，`SessionManager DBus: 空闲`，`gnome-session target: 无` | **正常**（Oracle Linux 10 没有 devkit，不走 gnome-session） |
| `gnome-shell: 0 个` | 桌面没起来，继续往下 |
| `应用窗口归属: 可能跑到 Windows 外层` | 配置没生效，跑一次 `~/start-desktop.sh` 会自动修 |

**① 桌面没起来，先确认 systemd / 用户对不对**（在 WSL 里跑）：

```bash
ps -p 1 -o comm=            # 必须输出 systemd；输出 init 说明没开
id -un                      # 不能是 root（GNOME 不能以 root 运行）
```

- 输出不是 `systemd`：`/etc/wsl.conf` 里要有 `[boot]` + `systemd=true`，然后在 Windows 执行
  `wsl --terminate 发行版名`，再重新运行安装脚本；
- 输出是 `root`：运行 `powershell -ExecutionPolicy Bypass -File .\oneclick\install.ps1 -Distro 发行版名`
  （安装器会创建普通用户 `u`，Oracle Linux 10 就是这样）。

**①.1 任务栏出现第二个 `Mutter Development Kit (发行版)` 窗口（其实是 gdm 登录界面）**

Fedora 等发行版装完桌面后会默认启用 `gdm.service`；WSL 里没有物理 seat，gdm 启动的 greeter
也会被我们的 gnome-shell override 套成 devkit 窗口，看起来像“多了一个桌面窗口”。

```bash
systemctl status gdm --no-pager | head -5     # active (running) 就是它
sudo systemctl disable --now gdm              # 安装器会自动执行这一步
```

Debian 的 gdm3 同理（`systemctl disable --now gdm3`）。停掉后窗口消失，不影响 `~/start-desktop.sh`。

**② 前台看启动日志**（把真正的报错打出来）：

```bash
~/start-desktop.sh --stop
~/start-desktop.sh --foreground 2>&1 | tail -40
```

常见报错与处理：

| 报错 | 原因 / 处理 |
|---|---|
| `Failed to start X Wayland: Directory "/tmp/.X11-unix" is not writable` | nested 模式默认要启动 Xwayland，但 WSLg 把它挂成只读；本项目启动时已加 `--no-x11`，如果你手动跑 `gnome-shell --nested`，也要加 `--no-x11` |
| `Context got an error: Failed to connect pipewire context` | PipeWire 没起来（Fedora/OL 实测）；`systemctl --user start pipewire.socket pipewire.service wireplumber.service` |
| `WL: unable to lock lockfile .../wayland-0.lock` | WSLg 的 `wayland-0` 软链被占用；本项目已改成显式用 `wayland-1`（见 4.9/本节 ③） |
| `Unit wsl-desktop-session.service was already loaded` | 桌面单元已存在（正常）；用 `~/start-desktop.sh`，不要手敲 `systemd-run` |

**③ 应用还是跑到 Windows 外层（nested 模式）**：

```bash
# 看嵌套 socket 是不是 wayland-1（不是就重启桌面）
ls -l /run/user/1000/wayland-* 2>/dev/null

# 看实际生效的启动参数（Fedora/Kali devkit 模式）
cat /etc/systemd/user/org.gnome.Shell@.service.d/override.conf 2>/dev/null

# 重新安装配置并重启（所有发行版通用）
wsl -d 发行版名 -u root -- bash -lc "bash /opt/wsl-desktop/install.sh --skip-packages"
~/start-desktop.sh --stop && ~/start-desktop.sh
```

### 4.11 把桌面语言改成中文（或改回英文）

GNOME 的界面语言由**启动桌面时的 `LANG`** 决定（不是装个语言包就自动变）。本项目约定：
`~/start-desktop.sh` 启动时会读取 `/etc/wsl-desktop/lang`，有就按里面的 `LANG`/`LANGUAGE` 启动。

**改成中文**（在 WSL 里，root）：

```bash
# 1) 生成中文 locale（只需要一次）
sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# 2) 告诉 start-desktop.sh 用中文（必须）
install -d -m 0755 /etc/wsl-desktop
printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > /etc/wsl-desktop/lang

# 3) 系统默认也设成中文（可选，但推荐；以后终端/新会话也是中文）
printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > /etc/default/locale

# 4) 让 D-Bus 激活的应用也拿到中文环境
install -d -o <用户名> -g <用户名> /home/<用户名>/.config/environment.d
printf 'LANG=zh_CN.UTF-8\nLANGUAGE=zh_CN:zh\n' > /home/<用户名>/.config/environment.d/00-locale.conf
chown <用户名>:<用户名> /home/<用户名>/.config/environment.d/00-locale.conf
```

然后**重启桌面**（会关掉当前窗口）：

```bash
~/start-desktop.sh --stop && ~/start-desktop.sh
```

验证：

```bash
pid=$(pgrep -f 'gnome-shell --devkit' | head -1); tr '\0' '\n' < /proc/$pid/environ | grep -E '^(LANG|LANGUAGE)='
# 期望：LANG=zh_CN.UTF-8 / LANGUAGE=zh_CN:zh
```

中文显示需要中文字体：Debian/Ubuntu 装 `fonts-noto-cjk`（`apt install -y fonts-noto-cjk`），
Fedora 装 `google-noto-sans-cjk-fonts`。没有字体时界面是中文但会显示方框。

**改回英文**：

```bash
rm -f /etc/wsl-desktop/lang
printf 'LANG=en_US.UTF-8\n' > /etc/default/locale
rm -f /home/<用户名>/.config/environment.d/00-locale.conf
~/start-desktop.sh --stop && ~/start-desktop.sh
```

> 已经实测：Debian（GNOME 51）执行完上面步骤后，顶栏/搜索框/应用名都变成中文（“输入以搜索”“设置”“实用工具”）。

**④ nested 模式的已知限制**（Oracle Linux 10）：

- 没有完整 `gnome-session`：系统设置/部分会话服务比 Ubuntu 少，属正常；
- 没有 Xwayland（`--no-x11`）：**纯 X11 程序不能在这个桌面里运行**，Wayland/GTK/Qt 应用正常；
- 如果 `dnf` 把 `gnome-shell` 升级到 49（RHEL 10 的 AppStream 同时提供 47/49，但 49 没有 `mutter-devkit`），
  nested 模式会失效——重新运行 `oneclick/install.ps1 -Distro oracle-linux-10` 会自动装回 47。

---

## 5. 声音问题

> ⚠️ 重要背景：WSLg 的音频服务（PulseAudio）**会周期性卡死 / 卡住后无声**，
> 这是 WSLg 1.0.79 的已知 bug，不是你的操作问题。
> 本项目已经用「看门狗 + 一键修复」尽量自动化。

### 5.1 先分清是哪种“没声音”

| 现象 | 大概率原因 | 去读 |
|---|---|---|
| 设置里「输出设备：无输出设备」 | WSLg 音频服务卡死 | [5.2](#52-设置里显示无输出设备音频服务卡死) |
| 有 RDP Sink、音量正常，但听不到 | Windows 输出设备选错 / 静音 / WSLg 播放路径异常 | [5.3](#53-有设备但没声音) |
| 只有浏览器没声（闹铃/其他有声） | snap 应用音频路由 | [5.4](#54-浏览器firefoxthunderbird没声音) |
| 播一会儿断、或播完就哑 | WSLg 卡死循环 | [5.2](#52-设置里显示无输出设备音频服务卡死) + [5.6](#56-什么时候需要重启整个-wsl) |

> 💡 **第一步永远是先跑一次 `~/start-desktop.sh`**（桌面已经在跑也不会重复启动，只做修复）：
> 它会自检音频、卡死就热重启 WSLg 的 PulseAudio，并顺手拉起剪贴板代理和桥。
> 2026-11-12 实测：热重启只需要约 3 秒，Weston 的播放线程会自动重连。

### 5.2 设置里显示“无输出设备”（音频服务卡死）

**诊断 [WSL]：**

```bash
PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C timeout 5 pactl info 2>&1 | grep -E "Default Sink" || echo "(卡死)"
tail -n 5 /tmp/audio-watch.log
```

`(卡死)` 或 `health=FAIL` → 音频服务卡住了。

**修复（任选一种）：**

**A. 先试这个（[WSL] 推荐）：**

```bash
~/start-desktop.sh
```

它会：音频自检 → 卡死就关掉「设置 > 声音」面板并热重启 WSLg 的 PulseAudio → 确认恢复 → 拉起剪贴板代理 → 启动桌面（已在跑就只修复）。

**B. 一键（[Windows] 推荐）**：

```powershell
powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\fix-audio.ps1"
```

**C. 不重启 WSL，只热重启音频（[Windows] 手工）：**

```powershell
wsl --system -- sh -c "pkill -9 pulseaudio"
```

等 5~10 秒，WSL 会自动把它拉起来，`/run/user/1000/pulse/native` 也会自动重挂。
再 [WSL] 验证：

```bash
PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C timeout 5 pactl info 2>&1 | grep -E "Default Sink"
```

**D. 彻底重启 WSL（最稳）：**

```powershell
wsl --shutdown
```

然后重新打开 Ubuntu 终端：

```bash
~/start-desktop.sh          # 后台启动（幂等；unit 已存在时会自动清理残留）
```

> 💡 **打开「设置 > 声音」面板有时会触发 WSLg 音频卡死**（本项目实测多次）。
> 从 2026-11-12 起有看门狗兜底：Windows 侧代理每 20 秒检测一次，发现卡死会**关掉面板 + 热重启音频**（约 20 秒恢复），恢复后重新点一下「声音」就能看到设备。
> 如果只是为了确认设备，也可以不打开面板，直接用命令：
>
> ```bash
> PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C pactl list short sinks
> ```

### 5.3 有设备、但没声音

按顺序检查：

**① Windows 输出设备是不是你正在用的那个**

你可能有：蓝牙耳机、USB 声卡（FiiO）、显示器音箱、内置扬声器……
WSLg 的声音会跟着 **Windows 默认输出设备** 走。点右下角喇叭图标，确认输出设备选对、音量不是 0、没静音。

> 如果默认输出是蓝牙耳机但耳机没戴 / 没连好，就会“一切都正常但没声音”。

**② 在 WSL 里放一个测试音，听一下**

```bash
PULSE_SERVER=unix:/mnt/wslg/PulseServer paplay /usr/share/sounds/freedesktop/stereo/complete.oga
```

- 有声音 → 音频链路 OK，问题在具体应用（见 5.4）
- 没声音但命令不报错 → 走 ③

**③ 检查 WSLg 的播放端是否活着**

```bash
grep -iE "Audio sink thread|rdpsnd" /mnt/wslg/weston.log | tail -5
```

如果反复出现 `Audio sink thread: error while reading from sink socket`，
说明 WSLg 的播放线程已经坏了 → **需要重启整个 WSL**（不是只重启 PulseAudio）：

```powershell
wsl --shutdown
```

然后重新打开 Ubuntu 终端并启动桌面。

**④ 看门狗已经在自动跑了（不用额外操作）**

Windows 侧剪贴板代理 `clip-agent.ps1` 自带音频看门狗：每 20 秒检测一次，卡死就自动关面板 + 热重启，并写日志：

```
C:\Users\Public\wsl-desktop-clip\agent.log
```

它由 `~/start-desktop.sh` 自动拉起，不需要再单独运行 `audio-watchdog.ps1`（旧脚本保留仅作参考）。
如果日志里反复出现 `audio FAIL` / `audio wedged`，说明卡死频率过高，直接用 D 方案重启 WSL。

### 5.4 浏览器（Firefox/Thunderbird）没声音

snap 版 Firefox/Thunderbird 的音频由 snapd 强制指向会话里的
`/run/user/1000/pulse/native`。本项目已把这个路径 **bind mount 到 WSLg 的音频服务**，
正常情况下不用管。若浏览器没声、但终端 `paplay` 有声音：

**① 确认会话 socket 挂载还在 [WSL]：**

```bash
ls -l /run/user/1000/pulse/native
mountpoint /run/user/1000/pulse/native
PULSE_SERVER=unix:/run/user/1000/pulse/native LC_ALL=C timeout 5 pactl info 2>&1 | grep "Default Sink"
```

若显示“不是挂载点 / 失败” → 重新挂载（正常情况下这是常驻服务，无需手动执行）：

```bash
sudo systemctl restart wslg-pulse-bind
```

（正常是由系统服务自动守护的，见 5.2）

**② 重启浏览器**（snap 应用会缓存音频连接）：

```bash
pkill -x firefox; sleep 2
```

再从桌面图标打开 Firefox 播放视频。

**③ 播放时检查 Firefox 的音频流有没有出现 [WSL]：**

```bash
PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C pactl list short sink-inputs
PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C pactl list short clients | grep -i firefox
```

- 有 firefox 流 → 音频进了 WSLg，问题在 Windows 输出设备（见 5.3 ①）
- 没有 firefox 流 → 浏览器没连上，看 ①/②，或重启桌面会话后重试

### 5.5 声音断续 / 卡顿

WSLg 的音频走 RDP 通道，对网络/CPU 负载敏感：

1. 检查是否在播放高清视频（浏览器同时占 CPU/GPU）；
2. 试着降低视频清晰度；
3. 蓝牙耳机（尤其“免提/Hands-Free”模式）延迟大、易断续 → 换有线/内置扬声器测试；
4. 卡顿后彻底没声 → 按 5.2 处理。

### 5.6 什么时候需要重启整个 WSL

满足任一条，直接 `wsl --shutdown` 再重开，别折腾：

- `pactl` 反复 FAIL，热重启 PulseAudio 后很快又 FAIL；
- **没有做热重启时**，`weston.log` 仍反复出现 `Audio sink thread: error while reading from sink socket`（注意：每次热重启瞬间都会出现一次，属于正常，会自动重连）；
- 设置面板反复显示“无输出设备”；
- 桌面和声音同时出现异常。

重启步骤：

```powershell
wsl --shutdown
```

等 10 秒，重新打开 Ubuntu 终端：

```bash
~/start-desktop.sh          # 后台启动（幂等；unit 已存在时会自动清理残留）
```

> 看门狗只是“临时保命”，**卡死循环时正确做法是重启 WSL**。

---

## 6. 剪贴板问题（2026-11-12 起为新方案）

**先记住 3 条：**

1. 只要 **桌面在跑**，`~/start-desktop.sh` 会自动拉起 Windows 侧代理 `clip-agent.ps1` 和 WSL 侧桥 `wsl-clipbridge`；
2. 双向都通，**纯文本**，延迟约 0.5~2 秒；图片/文件不支持；
3. 方案**不依赖 WSLg 自带剪贴板**，所以 WSLg 剪贴板卡死（`weston.log` 里 `outstanding RDP data request`）也不影响，看到这些日志可以忽略。

**工作方式（想看原理再看）：**

| 部件 | 位置 | 作用 |
|---|---|---|
| `clip-agent.ps1` | Windows 隐藏常驻 | 读写 Windows 剪贴板；交换目录在 `C:\Users\Public\wsl-desktop-clip\` |
| `win.txt` | 交换目录 | Windows 剪贴板快照（Linux 侧读它） |
| `linux.req.txt` | 交换目录 | Linux 侧要求写入 Windows 的文本 |
| `wsl-clipbridge` | WSL 用户服务 | 把内层 GNOME 剪贴板 ⇄ 交换目录同步 |

**一键检查 [WSL]：**

```bash
~/start-desktop.sh --check
```

期望（两行都要对）：

```
剪贴板代理(Windows):    在跑
剪贴板桥(服务):         active
```

**一键修复 [WSL]：**

```bash
~/start-desktop.sh
```

代理心跳过期会自动重启；桥没起来会自动 `systemctl --user start wsl-clipbridge`。

**按现象继续排查：**

**① 复制了但粘贴不出来（Windows → Linux 方向）**

[WSL] 先确认交换文件收到了内容（在 Windows 里复制一段文字后等 1~2 秒再执行）：

```bash
cat /mnt/c/Users/Public/wsl-desktop-clip/win.txt; echo
```

- 有内容 → 代理正常，问题在桥：`journalctl --user -u wsl-clipbridge -n 30 --no-pager`，然后 `systemctl --user restart wsl-clipbridge`
- 没内容 → 代理没在跑：看 `C:\Users\Public\wsl-desktop-clip\agent.heartbeat` 的修改时间是不是 5 秒内；不是就执行下面 [Windows] 手工启动：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\wsl-desktop-clip\clip-agent.ps1
```

**② 复制了但 Windows 里粘贴不出来（Linux → Windows 方向）**

[WSL] 测试内层剪贴板本身是否正常：

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
printf TEST123 | wl-copy; sleep 1; wl-paste -n; echo
tail -n 5 /tmp/clipbridge.log
cat /mnt/c/Users/Public/wsl-desktop-clip/linux.req.txt; echo
```

- `wl-paste` 能读出 `TEST123`，日志里也有「内层 -> Windows」→ 再看 [Windows] 的 `agent.log` 里有没有「linux -> win」
- `wl-paste` 读不出来 → 内层桌面剪贴板异常，`~/start-desktop.sh --stop && ~/start-desktop.sh` 后重试

**③ 中文/多行文本**

中文正常（UTF-8）。多行文本会保留换行；超大文本（>1 MiB）会被跳过并记日志。

**④ 双向都不通：GNOME Shell 扩展被自动禁用了（桌面崩溃/重启后常见）**

`gnome-shell` 异常退出后，GNOME 会启动 `org.gnome.Shell-disable-extensions.service`，把
`org.gnome.shell disable-user-extensions` 设为 `true`，于是剪贴板扩展也停掉——
这时代理和桥都是正常的（`--check` 前两行是绿的），但复制粘贴就是没反应。

[WSL] 检查：

```bash
gsettings get org.gnome.shell disable-user-extensions   # true = 被全局禁用
gnome-extensions info clipbridge@wsl-desktop | grep 已启用   # 否 = 扩展没在跑
```

一键修复（`~/start-desktop.sh` / `--fix` 已自动做）：

```bash
~/start-desktop.sh --fix
```

等价的手动命令：

```bash
gsettings set org.gnome.shell disable-user-extensions false
rm -f "$XDG_RUNTIME_DIR/gnome-shell-disable-extensions"
gnome-extensions enable clipbridge@wsl-desktop
```

**⑤ 同时开了多个发行版的桌面 → 剪贴板互相抢**

Windows 侧的交换目录是全局的（`C:\Users\Public\wsl-desktop-clip`），
多个发行版的桌面同时运行时，每个桌面的扩展都会往同一个 `linux.req.txt` 写、也都从同一个
`win.txt` 读，于是 Windows 剪贴板会被“最后那个桌面”覆盖，看起来像时好时坏。

处理办法：**一次只开一个桌面**（推荐）。想看另一个发行版时先关掉当前的：

```bash
# 在当前桌面所属发行版里
~/start-desktop.sh --stop
```

确认只剩一个桌面窗口（任务栏里只有一个 `Mutter Development Kit (...)` 或 `gnome-shell (...)`）。

**⑥ 全都试过还不行**

```powershell
# [Windows] 彻底重来：重启 WSL
wsl --shutdown
```

然后重新打开 Ubuntu 终端，执行 `~/start-desktop.sh`（会自动拉起代理和桥）。

---

## 7. 一键收集诊断信息（发给我/发 issue 用）

[WSL] 里整段复制粘贴：

```bash
{
  echo "===== 时间 ====="; date
  echo "===== 内核/发行版 ====="; uname -a; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
  echo "===== WSL ====="; wsl.exe --version 2>/dev/null | tr -d '\r'
  echo "===== 桌面 ====="; ~/start-desktop.sh --check 2>&1
  echo "===== 桌面进程 ====="; pgrep -a -x gnome-shell; pgrep -a -x mutter-devkit
  echo "===== 服务 ====="
  for u in wsl-clipbridge wsl-desktop-session; do echo "$u=$(systemctl --user is-active $u 2>/dev/null)"; done
  echo "wslg-pulse-bind=$(systemctl is-active wslg-pulse-bind 2>/dev/null)"
  echo "===== 音频 ====="
  PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C timeout 5 pactl info 2>&1 | head -12
  PULSE_SERVER=unix:/mnt/wslg/PulseServer LC_ALL=C timeout 5 pactl list short sinks 2>&1
  tail -n 10 /tmp/audio-watch.log 2>/dev/null
  echo "===== weston 音频错误 ====="; grep -iE "Audio sink thread" /mnt/wslg/weston.log 2>/dev/null | tail -5
  echo "===== PulseAudio 日志 ====="; tail -n 20 /mnt/wslg/pulseaudio.log 2>/dev/null
  echo "===== 剪贴板 ====="; systemctl --user is-active wsl-clipbridge; tail -n 10 /tmp/clipbridge.log 2>/dev/null
  echo "----- Windows 剪贴板代理 -----"; ls -l /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat 2>/dev/null; tail -n 10 /mnt/c/Users/Public/wsl-desktop-clip/agent.log 2>/dev/null
  echo "----- 交换目录 -----"; ls -l /mnt/c/Users/Public/wsl-desktop-clip/ 2>/dev/null
} > /tmp/wsl-desktop-diagnostics.txt 2>&1
echo "已生成：/tmp/wsl-desktop-diagnostics.txt"
```

然后 [Windows] 复制到桌面：

```powershell
wsl -d Ubuntu -- cp /tmp/wsl-desktop-diagnostics.txt /mnt/c/Users/$env:USERNAME/Desktop/
```

---

## 8. 完全重装 / 回滚

**重装（保留发行版，只重置桌面配置）：**

```bash
# WSL 内
~/stop-desktop.sh
sudo bash /mnt/c/你的路径/wsl-desktop/audio/install-audio.sh
sudo bash /mnt/c/你的路径/wsl-desktop/clipboard/install-clipbridge.sh
bash /mnt/c/你的路径/wsl-desktop/clipboard/enable-clipbridge.sh
bash /mnt/c/你的路径/wsl-desktop/audio/setup-snap-audio.sh
```

```powershell
# Windows 侧
wsl --shutdown
```

**回滚（把桌面相关改动去掉）：**

```bash
# WSL 内
sudo systemctl disable --now wslg-pulse-bind
sudo rm -f /etc/systemd/system/wslg-pulse-bind.service /usr/local/bin/wslg-pulse-bind
sudo rm -f /etc/systemd/user/org.gnome.Shell@.service.d/override.conf
rm -f ~/start-desktop.sh ~/stop-desktop.sh
systemctl --user disable --now wsl-clipbridge
rm -f ~/.config/systemd/user/wsl-clipbridge.service /usr/local/bin/clipbridge
```

**彻底重来**：备份后 `wsl --unregister Ubuntu` 再重装（会删掉整个发行版，慎用）。

---

## 9. 命令速查表

### Windows（PowerShell）

| 想做什么 | 命令 |
|---|---|
| 看 WSL/WSLg 版本 | `wsl --version` |
| 重启 WSL | `wsl --shutdown` |
| 一键修声音 | `powershell -ExecutionPolicy Bypass -File .\oneclick\fix-audio.ps1` |
| 一键重开桌面 | `powershell -ExecutionPolicy Bypass -File .\oneclick\restart-desktop.ps1` |
| 一键安装 | `powershell -ExecutionPolicy Bypass -File .\oneclick\install.ps1` |
| 热重启 WSLg 音频 | `wsl --system -- sh -c "pkill -9 pulseaudio"` |
| 看剪贴板代理日志 | `Get-Content C:\Users\Public\wsl-desktop-clip\agent.log -Tail 20` |
| 手工启动剪贴板代理 | `powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\wsl-desktop-clip\clip-agent.ps1` |
| **启动桌面（不占终端）** | `powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1` |
| 查看桌面状态 | `powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Status` |
| 停止桌面 | `powershell -ExecutionPolicy Bypass -File .\oneclick\start-desktop.ps1 -Stop` |
| **任意目录启动/查看/停止（不依赖仓库路径）** | `wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"`（把最后一段换成 `--check` / `--stop` / `--fix`） |
| 启动桌面（`systemd-run` 原写法，仅首次/备用） | `wsl -d Ubuntu -u <用户名> -- bash -lc "systemd-run --user --unit=wsl-desktop-session --collect /home/<用户名>/start-desktop.sh"`（单元已存在时会报 already loaded，属正常） |

### WSL（Ubuntu 终端）

| 想做什么 | 命令 |
|---|---|
| **启动桌面（后台，不占终端）** | `~/start-desktop.sh` |
| 查看会话状态 | `~/start-desktop.sh --check` |
| 只修声音/剪贴板 | `~/start-desktop.sh --fix` |
| 停止桌面 | `~/start-desktop.sh --stop`（或 `~/stop-desktop.sh`） |
| 重启桌面 | `~/start-desktop.sh --stop && ~/start-desktop.sh` |
| 前台启动（占终端，看日志） | `~/start-desktop.sh --foreground` |
| 看音频是否正常 | `PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl list short sinks` |
| 放测试音 | `PULSE_SERVER=unix:/mnt/wslg/PulseServer paplay /usr/share/sounds/freedesktop/stereo/complete.oga` |
| 看音频监控日志 | `tail -n 20 /tmp/audio-watch.log` |
| 看剪贴板桥日志 | `tail -n 20 /tmp/clipbridge.log` |
| 看剪贴板代理日志 | `tail -n 20 /mnt/c/Users/Public/wsl-desktop-clip/agent.log` |
| 看代理心跳 | `ls -l /mnt/c/Users/Public/wsl-desktop-clip/agent.heartbeat` |
| 剪贴板自测 | `bash /mnt/c/Users/<用户名>/Desktop/wsl2-nested-gnome-desktop/wsl-desktop/clipboard/final-clip-test.sh` |
| 装 flatpak 应用（用户级，不会弹「需要认证」） | `flatpak install --user flathub <应用ID>` |
| 关闭桌面图标扩展（防闪烁/警告） | `gnome-extensions disable ding@rastersoft.com` |
| 查看/切换剪贴板同步方式（扩展 or 旧轮询） | `~/start-desktop.sh --check`（看「剪贴板同步」行） |
| 启用剪贴板 Shell 扩展（无窗口） | `gnome-extensions enable clipbridge@wsl-desktop` |
| 重启剪贴板桥 | `systemctl --user restart wsl-clipbridge` |
| **应用窗口跑到 Windows 外层**（任务栏出现「计算器 (Ubuntu)」等单独窗口） | `~/start-desktop.sh --fix`，再 `~/start-desktop.sh --stop && ~/start-desktop.sh`（4.9） |
| **复制粘贴突然没反应**（代理/桥都正常） | `~/start-desktop.sh --fix`（自动恢复被 GNOME 禁用的剪贴板扩展，见 6 ④） |

---

## 10. 常见英文报错对照表

| 报错 | 含义 | 处理 |
|---|---|---|
| `A graphical session is already running!` | 上次会话残留 | `~/stop-desktop.sh` 后重开，或直接新 `start-desktop.sh`（会自愈） |
| `Connection failure: Connection refused`（pactl） | WSLg 音频服务卡死 | 5.2 |
| `Failed to connect to a Wayland server` | 桌面会话没起来 / socket 不存在 | 4.2 / 4.3 |
| `Failed to open service channel Wayland connection` | 桌面正在退出时的残留报错 | 一般无害 |
| `Audio sink thread: error while reading from sink socket` | WSLg 播放线程在音频服务重启/退出时的报错 | 热重启后会自动重连（本项目实测约 3 秒恢复），持续出现才需重启 WSL（5.6） |
| `asyncq.c: q overrun, queuing locally`（`/mnt/wslg/pulseaudio.log`） | WSLg 的 RDP 音频队列堵死 = 音频卡死 | 跑 `~/start-desktop.sh` 自动热重启（5.2） |
| `outstanding RDP data request` / `outstanding selection exist`（`/mnt/wslg/weston.log`） | 旧剪贴板方案触发的 WSLg 剪贴板卡死 | 新剪贴板方案已绕开，可忽略 |
| `blocked by the wayland surface` 等 GTK 警告 | 渲染/显卡警告 | 一般无害 |
| `tail: option used in invalid context` | Ubuntu 26.04 的 uutils tail 语法坑 | 用 `tail -n 20 文件` |
| `Unit wsl-desktop-session.service could not be found` | 桌面单元已退出 | 重新启动桌面 |
| `Failed to start transient service unit: Unit wsl-desktop-session.service was already loaded or has a fragment file` | 桌面单元已存在（桌面在运行，或上次关窗口后残留） | **不是错误**：改用 `~/start-desktop.sh`（幂等，自动清理残留）；或 `--stop` 后重开（4.5） |
| `-File 形式参数的实际参数“.\oneclick\start-desktop.ps1”不存在` | 当前 PowerShell 目录不是仓库根目录 | 先 `cd` 到仓库、或用完整路径、或双击 `oneclick\start-desktop.cmd`（4.5） |
| `Authentication is required to modify a system repository`（「需要认证」弹窗） | Flatpak 系统级安装/更新在请求管理员授权 | 用 `flatpak install --user …`；或 `Ctrl+C` / `pkill -f "flatpak install"` 结束安装（4.6） |
| `警告` / `Desktop Icons NG 正在 X11Wayland 下运行`（任务栏图标反复闪烁） | 桌面图标扩展 ding 继承了 shell 的 `GDK_BACKEND=x11`，在 `--no-x11` 嵌套会话里反复重建桌面窗口并弹警告 | 脚本已自动禁用；手动：`gnome-extensions disable ding@rastersoft.com`（4.7） |
| 任务栏齿轮图标反复闪（左侧带橙色运行点） | 旧剪贴板桥定期调用 `wl-paste`，wl-clipboard 每次都创建临时窗口，Dock 把它当“未知应用”显示 | 已改为 GNOME Shell 扩展同步剪贴板（无窗口）；`~/start-desktop.sh --check` 看「剪贴板同步」（4.8） |
| 任务栏出现「计算器 (Ubuntu)」「软件更新器 (Ubuntu)」等单独窗口（应用跑到 Ubuntu 桌面外面） | gnome-shell 的 override 带了 `GDK_BACKEND=x11`，它启动的应用继承后连到 WSLg 外层 X11 `:0` | 跑 `~/start-desktop.sh --fix` 修复配置，再重启桌面（4.9） |
| 复制粘贴突然没反应（`--check` 里代理/桥都正常） | 桌面崩溃后 GNOME 自动禁用了用户扩展（`disable-user-extensions=true`），剪贴板扩展停掉 | 跑 `~/start-desktop.sh --fix`（6 ④） |
| `WSL_E_DISTRO_NOT_FOUND` | 发行版名字不对 | `wsl -l -v` 看真实名字 |

---

## 11. 仍然解决不了？

把 [第 7 节](#7-一键收集诊断信息发给我发-issue-用) 生成的
`wsl-desktop-diagnostics.txt` 发出来，里面包含了定位问题需要的信息。

---

*本指南会随项目更新；遇到新问题欢迎补充到仓库 `wsl-desktop/TROUBLESHOOTING.md`。*
