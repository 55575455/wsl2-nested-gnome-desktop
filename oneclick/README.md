# oneclick —— 给“不会 Linux”的人用的一键脚本

> ⚠️ **公开仓库（脱敏版）用户先做这一步**：仓库里的个人路径是占位符（`C:\Users\<用户名>`、`/home/<用户名>`、`~/wsl2-nested-gnome-desktop` …），
> **必须**替换成本机实际路径。在仓库根目录运行：
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1          # 查看实际路径 + 列出所有脱敏文件位置
> powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1 -Apply    # 确认后自动替换
> ```
>
> 仓库只在 WSL 里时也可以用：`bash oneclick/show-paths.sh`（加 `--apply` 自动替换）。
> 实际路径版（未脱敏）会提示「未发现占位符」，可跳过。

这些脚本都是**自包含**的（所有配置内容都内嵌在文件里），
发给别人时只需要把文件内容整段复制给对方，对方保存成 `.ps1` 运行即可。

| 脚本 | 用途 | 运行方式（Windows PowerShell） |
|---|---|---|
| `show-paths.ps1` / `show-paths.sh` | **公开仓库必读**：显示本机实际值 + 列出所有含占位符的脱敏文件；`-Apply`/`--apply` 自动填写 | `powershell -ExecutionPolicy Bypass -File .\show-paths.ps1` |
| `install.ps1` | 一键安装：检查 WSLg → 装桌面组件 → 配剪贴板/声音 → 启动桌面（`-Distro` / `-All` / `-User`） | `powershell -ExecutionPolicy Bypass -File .\install.ps1` |
| `start-desktop.ps1` / `start-desktop.cmd` | **一键启动桌面（后台，立即返回，不占终端）**；`-Status` 看状态、`-Stop` 停止、`-FixOnly` 只修声音/剪贴板、`-Wait` 等窗口出现 | `powershell -ExecutionPolicy Bypass -File .\start-desktop.ps1`（任意目录：用完整路径或双击 `.cmd`） |
| `fix-audio.ps1` | 一键修声音：先让 `~/start-desktop.sh --fix` 自检并热重启音频（约 3 秒恢复），不行再重启 WSL、重开桌面 | `powershell -ExecutionPolicy Bypass -File .\fix-audio.ps1` |
| `restart-desktop.ps1` | 一键重开桌面（清理残留会话 + 启动，同时会修声音/剪贴板） | `powershell -ExecutionPolicy Bypass -File .\restart-desktop.ps1` |

> 💡 2026-11-12 起：`~/start-desktop.sh` 默认**后台启动**（桌面交给 systemd 用户单元，脚本立即返回，**终端不被占用**），
> 每次运行都会自动修复声音（热重启卡死的 WSLg PulseAudio）、拉起 Windows 侧剪贴板代理并启动剪贴板桥。
> 日常「没声音 / 没剪贴板」→ `~/start-desktop.sh --fix`；需要看前台日志 → `~/start-desktop.sh --foreground`。

## 从哪里运行（重要）

- `.\oneclick\xxx.ps1` 这种写法**要求当前目录是仓库根目录**；
- 从开始菜单打开的 PowerShell 默认在 `C:\windows\System32`，直接粘贴会报
  `-File 形式参数的实际参数“.\oneclick\start-desktop.ps1”不存在`，这**不是脚本坏了**，是目录不对；
- 解决办法（任选）：
  1. 先 `cd` 到仓库目录，再运行；
  2. 用完整路径：`powershell -ExecutionPolicy Bypass -File "C:\你的路径\oneclick\start-desktop.ps1"`；
  3. **双击** `start-desktop.cmd`——它用 `%~dp0` 自动定位同目录的 `.ps1`，和当前目录无关；
- 完全不依赖目录的启动方式（Windows 任意位置，推荐记这一条）：

  ```powershell
  wsl -d Ubuntu -u <用户名> -- bash -lc "~/start-desktop.sh"      # 启动（幂等，立即返回，不占终端）
  ```

> 另外：**不要反复手动执行 `systemd-run --user --unit=wsl-desktop-session ...` 原命令**。
> 桌面单元已存在时（桌面在跑，或上次关窗口后残留）它会报
> `Unit wsl-desktop-session.service was already loaded or has a fragment file`——这是正常的，
> 用 `~/start-desktop.sh` 即可（幂等，会自动清理残留单元）。

## 支持的发行版

`install.ps1` 自动识别 apt / dnf，并按发行版选择桌面组件和启动模式：

| 发行版 | 桌面组件 | 桌面模式 | 窗口标题 |
|---|---|---|---|
| Ubuntu 26.04 | `ubuntu-desktop` + `mutter-dev-bin` | devkit | `Mutter Development Kit (Ubuntu)` |
| Fedora 45 | `gnome-shell` + `mutter-devkit` | devkit | `Mutter Development Kit (FedoraLinux-45)` |
| Kali 2026 | 最小 GNOME 集合 + `mutter-dev-bin` | devkit | `Mutter Development Kit (kali-linux)` |
| Oracle Linux 10 | `gnome-shell-47` + `mutter-47`（没有 devkit） | nested | `gnome-shell (oracle-linux-10)` |
| Debian | `gnome-shell` + `mutter` | devkit / nested 自动判断 | 同上 |

```powershell
# 只装一个
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro FedoraLinux-45
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro kali-linux
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro oracle-linux-10

# 所有已安装发行版（逐个装，最后汇总；失败不会中断其它发行版）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -All
```

> Oracle Linux 10 的 WSL 镜像默认没开 systemd、没有普通用户、没配 AppStream 仓库：
> 安装器会写 `/etc/wsl.conf`、自动 `wsl --terminate` 后重试，并创建普通用户 `u`。
> 第一次安装会多花一两分钟，属正常。

## 安装脚本的可选参数

```powershell
# 只检查，不做改动
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

# 已经装过桌面组件，只更新脚本/配置（不重复下载；兼容旧参数名 -SkipApt）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipPackages

# 安装配置但不自动启动桌面
powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoStart

# 指定用户（默认自动用发行版里的普通用户；没有就创建 u）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro OracleLinux -User u

# 发行版名字不是 Ubuntu（比如装的时候自定义了名字）
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Distro 你的发行版名
```

## 发给别人（对方没有本仓库）

1. 用记事本打开对应 `.ps1`，**全选 → 复制**；
2. 通过微信/QQ/邮件发给对方；
3. 对方粘贴到新文件（如 `install.ps1`），保存；
4. 对方在 PowerShell 里运行命令行版本，或右键“使用 PowerShell 运行”。

> 注意：首次安装会下载 2~5 GB 的桌面组件，需要网络和磁盘空间。

## 出问题

看 [../wsl-desktop/TROUBLESHOOTING.md](../wsl-desktop/TROUBLESHOOTING.md)，
里面全是“复制粘贴即可”的排查步骤。

最常见的两个启动报错（`-File ... 不存在`、`Unit ... was already loaded`）
整理在 [TROUBLESHOOTING 4.5 节](../wsl-desktop/TROUBLESHOOTING.md)。
