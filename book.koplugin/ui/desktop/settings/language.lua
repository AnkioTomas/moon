--[[-- 语言与输入设置项。
@module koplugin.book.ui.desktop.settings.language
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local Popup = require("ui.components.popup")
local SettingRow = require("ui.components.settingrow")
local UI = require("ui.components.bookui")
local Paths = require("utils.paths")
local IME = require("ime.init")
local Registry = require("ime.registry")
local _ = require("gettext")
local T = require("ffi/util").template

local Language = {}
local RELEASES_URL = "https://github.com/AnkioTomas/moon/releases"

--- 造一行小字灰色提示，高度按文本实测撑开。
---@param width number 行可用宽度
---@param text string 提示文案
---@return table LeftContainer widget
local function hintRow(width, text)
    local box_w = math.max(1, width - UI.sz(4))
    local box = TextBoxWidget:new{
        text = text,
        face = UI.face("xx_smallinfofont", 11),
        width = box_w,
        fgcolor = UI.muted(),
    }
    -- LeftContainer 只设 w 时 dimen.h 为 0：VerticalGroup 不预留高度，paintTo 会把正文往上顶到上一行。
    local box_h = box:getSize().h
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = box_h },
        box,
    }
end

--- 弹出界面语言选择列表。
--- 选项与回调都直接取自 KOReader 原生语言菜单，切换行为完全交给它。
local function pickLanguage()
    local source = require("ui/language"):getLangMenuTable()
    local items = {}
    for _idx, item in ipairs(source.sub_item_table or {}) do
        items[#items + 1] = {
            text = item.text,
            checked = item.checked_func and item.checked_func(),
            callback = item.callback,
        }
    end
    Popup.list{ title = _("语言"), items = items }
end

--- 选择当前中文输入法。
---@param desktop table
local function pickInputMethod(desktop)
    local current = IME.layout()
    local items = {}
    for _, method in ipairs(IME.layouts()) do
        items[#items + 1] = {
            text = method.id == current and "✓ " .. method.label or method.label,
            callback = function()
                IME.setLayout(method.id)
                desktop:rebuild()
            end,
        }
    end
    Popup.sheet{ title = _("键盘布局"), items = items }
end

--- 下载当前输入法词库，全程用进度对话框回报 manifest / 分片 / 拼接三个阶段。
--- 已在下载中则直接返回，避免并发拉取。
---@param desktop table 桌面实例，结束后重建以刷新状态文案
---@param enable_after boolean|nil 下载成功后是否顺带开启中文输入增强
local function download(desktop, enable_after)
    if require("ime.download").downloading() then return end
    local dialog
    local dialog_has_bar = false
    --- 关掉当前进度对话框（若有）。
    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
        dialog_has_bar = false
    end
    --- 换一个进度对话框；总量未知时退化成无进度条的等待提示。
    ---@param opts table ProgressbarDialog 参数
    local function openDialog(opts)
        closeDialog()
        local ok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
        if not ok then return end
        dialog = ProgressbarDialog:new(opts)
        dialog_has_bar = opts.progress_max ~= nil and opts.progress_max > 0
        dialog:show()
    end
    -- manifest 拉取前无总量，先给即时反馈，避免确认框关闭后长时间空白。
    openDialog{
        title = _("正在准备下载输入法词库…"),
        subtitle = _("请稍候…"),
        refresh_time_seconds = 1,
        dismissable = false,
    }
    IME.downloadDict(function(ok, err)
        closeDialog()
        UIManager:show(InfoMessage:new{
            text = ok and _("输入法词库已就绪") or T(_("下载失败: %1"), tostring(err or "未知错误")),
            timeout = 2,
        })
        if ok and enable_after then IME.setEnabled(true) end
        desktop:rebuild()
    end, function(stage, done_bytes, total, _idx, count)
        if stage == "assemble" then
            closeDialog()
            UIManager:show(InfoMessage:new{ text = _("拼接校验词库…"), timeout = 2 })
            return
        end
        if (stage == "manifest" or stage == "part") and total and total > 0 then
            if not dialog_has_bar then
                openDialog{
                    title = stage == "manifest"
                        and _("正在准备下载输入法词库…") or _("正在下载输入法词库…"),
                    subtitle = T(_("共 %1 片"), count) .. string.format(" · %.1f MB", total / 1048576),
                    progress_max = total, refresh_time_seconds = 1, dismissable = false,
                }
            elseif stage == "part" then
                dialog:reportProgress(done_bytes)
            end
        end
    end)
end

--- 下载词库前先确认，提醒新词库可能要求新版插件。
---@param desktop table 桌面实例
---@param enable_after boolean|nil 下载成功后是否顺带开启中文输入增强
local function confirmDownload(desktop, enable_after)
    UIManager:show(ConfirmBox:new{
        text = _("新词库可能需要新版插件支持。是否继续下载？"),
        ok_text = _("继续下载"), ok_callback = function() download(desktop, enable_after) end,
    })
end

---@param desktop table
---@return table
function Language.rows(desktop)
    local lang = G_reader_settings:readSetting("language") or "C"
    local LanguageApi = require("ui/language")
    local method = Registry.current()
    local dict_path = Paths.imeDictPath(method.id)
    return {
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "language", title = _("语言"),
                status = LanguageApi:getLanguageName(lang), status_on = true,
                callback = pickLanguage,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "toggle", icon = "translate", title = _("中文输入法增强"),
                status = IME.isEnabled() and _("开") or _("关"), status_on = IME.isEnabled(),
                callback = function()
                    if not IME.isEnabled() and not Registry.isAvailable(method) then
                        confirmDownload(desktop, true)
                        return
                    end
                    local on = IME.setEnabled(not IME.isEnabled())
                    UIManager:show(InfoMessage:new{
                        text = on and _("中文键盘已启用，点键盘上的 🌐 键切换中英文") or _("中文键盘已停用"),
                        timeout = 3,
                    })
                    desktop:rebuild()
                end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "keyboard", title = _("键盘布局"),
                status = method.label, status_on = true,
                callback = function() pickInputMethod(desktop) end,
            })
        end,
        function(iw)
            return SettingRow.build(iw, {
                kind = "nav", icon = "spellcheck", title = _("输入法词库"),
                status = IME.dictStatus(),
                status_on = Registry.isAvailable(method),
                callback = function() confirmDownload(desktop) end,
            })
        end,
        function(iw)
            return hintRow(iw, T(_(
                "若在线下载过慢，可到 GitHub Release（%1）下载对应词库，重命名后放入：%2"
            ), RELEASES_URL, dict_path))
        end,
    }
end

return Language
