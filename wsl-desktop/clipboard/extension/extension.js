// WSL Desktop clipboard bridge —— GNOME Shell 扩展
//
// 在 gnome-shell 进程里直接读写剪贴板（compositor 上下文，不需要窗口、不需要焦点），
// 通过文件与 Windows 侧的 clip-agent.ps1 交换内容：
//   /mnt/c/Users/Public/wsl-desktop-clip/win.txt        Windows 剪贴板快照（→ 内层）
//   /mnt/c/Users/Public/wsl-desktop-clip/linux.req.txt  内层剪贴板（→ Windows）
//
// 这样就不再需要每 0.2 秒运行一次 wl-paste / wl-copy —— wl-clipboard 每次运行都会
// 创建临时窗口（被 Dock 当成“未知应用”显示成齿轮图标闪烁、还会抢焦点），
// 现在剪贴板同步完全在 shell 内部完成，没有任何窗口。
import GLib from 'gi://GLib';
import St from 'gi://St';

const SHARE_DIR = '/mnt/c/Users/Public/wsl-desktop-clip';
const WIN_FILE = `${SHARE_DIR}/win.txt`;
const REQ_FILE = `${SHARE_DIR}/linux.req.txt`;
const MAX_TEXT = 1048576;          // 1 MiB
const WIN_POLL_MS = 400;           // 检查 Windows 侧文件的间隔
const INNER_POLL_MS = 400;         // 检查内层剪贴板的间隔

export default class ClipbridgeExtension {
    constructor() {
        this._clip = null;
        this._lastWin = null;       // 最近一次从 win.txt 取到的内容
        this._lastInner = null;     // 最近一次同步过的内层内容（防回环）
        this._winTimer = 0;
        this._innerTimer = 0;
    }

    enable() {
        this._clip = St.Clipboard.get_default();
        log('clipbridge: extension enabled');

        // 启动时只记录当前内层内容（不回写，避免覆盖两边）；
        // Windows 剪贴板对齐交给下面的定时器（等首次内层读取完成后再比较，避免回环）
        this._readInner(false);

        this._winTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, WIN_POLL_MS, () => {
            this._syncWindowsToInner();
            return GLib.SOURCE_CONTINUE;
        });
        this._innerTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, INNER_POLL_MS, () => {
            this._readInner(true);
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        for (const id of [this._winTimer, this._innerTimer]) {
            if (id) {
                try { GLib.source_remove(id); } catch (e) { }
            }
        }
        this._winTimer = 0;
        this._innerTimer = 0;
        this._clip = null;
    }

    _readFile(path, maxLen) {
        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            if (!ok || bytes === null)
                return null;
            const text = new TextDecoder('utf-8').decode(bytes);
            if (text.length > maxLen)
                return null;
            return text;
        } catch (e) {
            return null;
        }
    }

    _writeFile(path, text) {
        try {
            GLib.file_set_contents(path, new TextEncoder().encode(text));
        } catch (e) {
            // ignore
        }
    }

    // 内层剪贴板变化 → 写到 linux.req.txt（Windows 代理会读取并写入 Windows 剪贴板）
    _readInner(sync) {
        if (!this._clip)
            return;
        this._clip.get_text(St.ClipboardType.CLIPBOARD, (_clipboard, text) => {
            if (typeof text !== 'string')
                return;
            if (text.length > MAX_TEXT)
                return;
            if (text === this._lastInner)
                return;
            this._lastInner = text;
            log(`clipbridge: inner changed (${text.length} chars, sync=${sync})`);
            if (sync)
                this._writeFile(REQ_FILE, text);
        });
    }

    // win.txt 变化 → 设置内层剪贴板（不抢焦点、不产生任何窗口）
    _syncWindowsToInner() {
        if (!this._clip)
            return;
        const text = this._readFile(WIN_FILE, MAX_TEXT);
        if (text === null)
            return;
        if (text === this._lastWin)
            return;
        this._lastWin = text;
        if (text === this._lastInner)
            return;
        this._lastInner = text;
        log(`clipbridge: win -> inner (${text.length} chars)`);
        this._clip.set_text(St.ClipboardType.CLIPBOARD, text);
    }
}
