#!/usr/bin/env bash
# 显示 / 填写本机实际路径（公开仓库·脱敏版必读）—— WSL 版
#
# 公开仓库是“脱敏版”：个人路径都被换成了占位符，例如
#   C:\Users\<用户名>            /home/<用户名>
#   <用户名>@<主机名>            ~/wsl2-nested-gnome-desktop
# 使用前必须把它们换成你本机的真实路径，否则路径不存在，安装/启动会失败。
#
# 本脚本会：
#   1) 显示本机实际值（WSL 用户名/home/主机名、仓库位置、Windows 路径）；
#   2) 列出仓库里所有“含占位符的文件”（脱敏文件位置）与出现次数；
#   3) 打印「占位符 → 你的实际值」对照表；
#   4) 加 --apply 可自动替换（用 python3，替换前会提示；不改脚本自身）。
#
# 用法（在 WSL 终端里，仓库任意位置）：
#   bash oneclick/show-paths.sh            # 只看
#   bash oneclick/show-paths.sh --apply    # 自动替换
#
# Windows 用户也可以改用：powershell -ExecutionPolicy Bypass -File .\oneclick\show-paths.ps1
set -u

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/.." && pwd)
REPO_NAME=$(basename "$REPO_ROOT")

head_line() {
  echo
  echo '=================================================================='
  echo "  $*"
  echo '=================================================================='
}
item() { printf '  %-24s : %s\n' "$1" "$2"; }

head_line '本机实际值（这些就是要填进去的内容）'
wsl_user=$(id -un)
wsl_home=$HOME
wsl_host=$(hostname 2>/dev/null || echo unknown)
item 'WSL 用户名' "$wsl_user"
item 'WSL 用户 home' "$wsl_home"
item 'WSL 主机名' "$wsl_host"
item '仓库在 WSL 的位置' "$REPO_ROOT"

win_user=''
win_home=''
if command -v cmd.exe >/dev/null 2>&1; then
  win_user=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' | head -n1)
  win_home=$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r' | head -n1)
fi
[ -z "$win_user" ] && win_user='<你的Windows用户名>'
[ -z "$win_home" ] && win_home="C:\\Users\\$win_user"
item 'Windows 用户名' "$win_user"
item 'Windows 用户目录' "$win_home"

repo_win=''
if command -v wslpath >/dev/null 2>&1; then
  repo_win=$(wslpath -w "$REPO_ROOT" 2>/dev/null || true)
fi
[ -z "$repo_win" ] && repo_win='<仓库在 Windows 下的路径>'
item '仓库在 Windows 的路径' "$repo_win"
echo "  （如果你是在 WSL 里 clone 的，Windows 里通常显示为 \\\\wsl.localhost\\<发行版>\\...）"

head_line '要求（使用公开仓库前必须做）'
echo '  1) 公开仓库（脱敏版）里，文档/脚本中的个人路径都是占位符；'
echo '  2) 必须把所有占位符替换成你本机的实际值（下表就是对照表）；'
echo "  3) 可以用本脚本的 --apply 自动替换，或照着下表手动改；"
echo '  4) 不替换的话，命令里的路径会指向不存在的位置，安装/启动会失败。'

head_line '占位符 → 你的实际值（照着填）'
printf '  %-30s →  %s\n' 'C:\Users\<用户名>' "$win_home"
printf '  %-30s →  %s\n' '/home/<用户名>' "$wsl_home"
printf '  %-30s →  %s\n' '<用户名>@<主机名>' "$wsl_user@$wsl_host"
printf '  %-30s →  %s\n' '-u <用户名>' "-u $wsl_user"
printf '  %-30s →  %s\n' '<用户名>' "$win_user"
printf '  %-30s →  %s\n' '<主机名>' "$wsl_host"
printf '  %-30s →  %s\n' '~/wsl2-nested-gnome-desktop' "$REPO_ROOT"

head_line '含占位符的文件（这些就是“公开仓库的脱敏文件位置”）'
cd "$REPO_ROOT" || exit 1
mapfile -t FILES < <(
  grep -rlF \
    -e '<用户名>' -e '<主机名>' -e '~/wsl2-nested-gnome-desktop' \
    --exclude-dir=.git --exclude='show-paths.sh' --exclude='show-paths.ps1' \
    . 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort
)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo '  未发现占位符：本仓库看起来已经是实际路径版，不需要填写。'
else
  echo "  共 ${#FILES[@]} 个文件需要检查/填写："
  for f in "${FILES[@]}"; do
    echo "  - $f"
    for token in 'C:\Users\<用户名>' '/home/<用户名>' '<用户名>@<主机名>' '-u <用户名>' '<用户名>' '<主机名>' '~/wsl2-nested-gnome-desktop'; do
      n=$(grep -oF -e "$token" -- "$f" 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] && printf '      占位符：%s×%s\n' "$token" "$n"
    done
    echo "      绝对路径：$REPO_ROOT/$f"
  done
fi

if [ "$APPLY" -eq 1 ]; then
  head_line '开始自动替换（--apply）'
  if [ "${#FILES[@]}" -eq 0 ]; then
    echo '  没有需要替换的内容。'
    exit 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo '[错误] 需要 python3 才能自动替换；请按上面的对照表手动修改。'
    exit 1
  fi
  echo '  将替换以下文件（可用 git diff 查看改动）：'
  printf '    %s\n' "${FILES[@]}"
  SP_WINHOME="$win_home" SP_WSLHOME="$wsl_home" SP_WSLUSER="$wsl_user" \
  SP_WSLHOST="$wsl_host" SP_WINUSER="$win_user" SP_REPO="$REPO_ROOT" \
  python3 - "${FILES[@]}" <<'PY'
import os, sys

mapping = [
    ('C:\\Users\\<用户名>', os.environ['SP_WINHOME']),
    ('/home/<用户名>', os.environ['SP_WSLHOME']),
    ('<用户名>@<主机名>', os.environ['SP_WSLUSER'] + '@' + os.environ['SP_WSLHOST']),
    ('-u <用户名>', '-u ' + os.environ['SP_WSLUSER']),
    ('<用户名>', os.environ['SP_WINUSER']),
    ('<主机名>', os.environ['SP_WSLHOST']),
    ('~/wsl2-nested-gnome-desktop', os.environ['SP_REPO']),
]

changed = 0
for rel in sys.argv[1:]:
    path = os.path.join(os.environ['SP_REPO'], rel)
    data = open(path, 'rb').read()
    bom = data.startswith(b'\xef\xbb\xbf')
    text = data.decode('utf-8-sig')
    orig = text
    for token, value in mapping:
        text = text.replace(token, value)
    if text != orig:
        b = text.encode('utf-8')
        if bom:
            b = b'\xef\xbb\xbf' + b
        open(path, 'wb').write(b)
        changed += 1
        print('  已替换：' + rel)
print('  完成：修改了 %d 个文件。' % changed)
print('  建议：git status 看一下改动；如果你要把改动推回仓库，请先确认没有混入个人信息。')
PY
else
  head_line '下一步'
  echo '  先按上面的对照表手工填写；也可以直接自动替换（会修改文件）：'
  echo
  echo '    bash oneclick/show-paths.sh --apply'
  echo
fi
