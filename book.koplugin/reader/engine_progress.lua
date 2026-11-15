--[[--
开书 / 重排的进度：KOReader 顶部的「Opening file」提示和左上角那根细线，统一换成主题进度弹窗
（和下载、更新用的是同一个 ProgressDialog）。

开书：`patchOpen` 一开始就弹窗（0%），crengine 回调时更新文案与进度，开完关窗。
进度 0–50% 是载入，50–100% 是排版。
阅读中重新排版没有开书弹窗：沿用原生的 2 秒后才出现、500 毫秒刷新一次，结束时关窗。
引擎回调期间 UIManager 不会跑，所以每次更新后 `forceRePaint` 同步重绘。
沿用原生开关 cre_show_progress。

@module koplugin.book.reader.engine_progress
--]]

local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local INITIAL_DELAY = time.s(2)
local UPDATE_DELAY = time.ms(500)

local EngineProgress = {
    --- 正在打开的书名；Open.book 设置，开书弹窗标题引用。
    opening_name = nil,
}

local function newDialog(title)
    local ProgressDialog = require("ui.themes.widgets.progress_dialog")
    return ProgressDialog:new{ title = title, dismissable = false }
end

local function label(fraction)
    return fraction <= 0.5 and _("正在载入书籍") or _("正在排版")
end

--- 只画弹窗本身并局部刷新。不能用 forceRePaint：它会重画整个窗口栈，阅读页绘制时
--- 触发文档再次排版，引擎回调又进来，无限递归（字体切换时一直「正在排版」）。
local function paintDialog(dialog)
    local Screen = require("device").screen
    dialog:paintTo(Screen.bb, 0, 0)
    local box = dialog[1] and dialog[1].dimen
    if box then Screen:refreshFast(box.x, box.y, box.w, box.h) end
end

local function closeDialog(owner, field)
    local dialog = owner[field]
    owner[field] = nil
    if dialog then dialog:close() end
end

--- 替换 ReaderUI 开书流程里的 InfoMessage：弹主题进度弹窗，开完（或失败）关掉。
function EngineProgress.patchOpen()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI._book_open_patched then return end
    ReaderUI._book_open_patched = true
    -- 引擎回调在文档载入期间就触发，早于阅读页 onCreate 的实例安装，所以在类上先接管。
    EngineProgress.install(require("apps/reader/modules/readerrolling"))
    ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        local UIManager = require("ui/uimanager")
        if not seamless then
            local name = EngineProgress.opening_name
            EngineProgress.opening_name = nil
            ReaderUI._book_open_dialog = newDialog(name and name ~= "" and T(_("正在打开《%1》"), name) or _("正在打开"))
            ReaderUI._book_open_dialog:show()
            UIManager:forceRePaint()
        else
            -- 切章时旧书已关，窗口栈里没有别的窗口就会让 KOReader 退出：保留原生不可见的占位消息。
            UIManager:show(require("ui/widget/infomessage"):new{ text = "", timeout = 0.0, invisible = true })
        end
        UIManager:nextTick(function()
            local co = coroutine.create(function()
                self:doShowReader(file, provider, seamless)
            end)
            local ok, err = coroutine.resume(co)
            closeDialog(ReaderUI, "_book_open_dialog")
            if err ~= nil or ok == false then
                io.stderr:write("[!] doShowReader coroutine crashed:\n")
                io.stderr:write(debug.traceback(co, err, 1))
                local Device = require("device")
                Device:setIgnoreInput(false)
                Device.input:inhibitInputUntil(0.2)
                require("ui.themes.widgets.toast"):new{ text = _("无法打开书籍") }:show()
                self:showFileManager(file)
            end
        end)
    end
end

--- 替换 ReaderRolling 实例上的 showEngineProgress（实例字段，不动 KOReader 类）。
---@param rolling table ReaderRolling
function EngineProgress.install(rolling)
    if not rolling or rolling._book_engine_progress then return end
    rolling._book_engine_progress = true
    rolling.showEngineProgress = function(self, fraction)
        if G_reader_settings and G_reader_settings:isFalse("cre_show_progress") then return end
        local ReaderUI = require("apps/reader/readerui")
        if not fraction then
            self.engine_progress_update_not_before = nil
            closeDialog(self, "_book_engine_dialog")
            return
        end
        if self._book_engine_painting then return end
        local now = time.now()
        local dialog = ReaderUI._book_open_dialog
        local not_before = self.engine_progress_update_not_before
        if not dialog and not not_before then
            self.engine_progress_update_not_before = now + INITIAL_DELAY
            return
        end
        if not_before and now < not_before then return end
        if not dialog then
            dialog = self._book_engine_dialog
            if not dialog then
                dialog = newDialog(_("正在排版"))
                self._book_engine_dialog = dialog
                dialog:show()
            end
        end
        self._book_engine_painting = true
        dialog:set(label(fraction), math.max(0, math.min(1, fraction)) * 100)
        paintDialog(dialog)
        self._book_engine_painting = nil
        self.engine_progress_update_not_before = now + UPDATE_DELAY
    end
end

return EngineProgress
