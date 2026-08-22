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
local Pinyin = require("pinyin.init")
local _ = require("gettext")
local T = require("ffi/util").template

local Language = {}
local RELEASES_URL = "https://github.com/AnkioTomas/moon/releases"

local function hintRow(width, text)
    return LeftContainer:new{
        dimen = Geom:new{ w = width },
        TextBoxWidget:new{
            text = text,
            face = UI.face("xx_smallinfofont", 11),
            width = math.max(1, width - UI.sz(4)),
            fgcolor = UI.muted(),
        },
    }
end

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

local function download(desktop, enable_after)
    if require("pinyin.download").downloading() then return end
    local dialog
    local dialog_has_bar = false
    local function closeDialog()
        if dialog then dialog:close(); dialog = nil end
        dialog_has_bar = false
    end
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
        title = _("正在准备下载拼音词库…"),
        subtitle = _("请稍候…"),
        refresh_time_seconds = 1,
        dismissable = false,
    }
    Pinyin.downloadDict(function(ok, err)
        closeDialog()
        UIManager:show(InfoMessage:new{
            text = ok and _("拼音词库已就绪") or T(_("下载失败: %1"), tostring(err or "未知错误")),
            timeout = 2,
        })
        if ok and enable_after then Pinyin.setEnabled(true) end
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
                    title = stage == "manifest" and _("正在准备下载拼音词库…") or _("正在下载拼音词库…"),
                    subtitle = T(_("共 %1 片"), count) .. string.format(" · %.1f MB", total / 1048576),
                    progress_max = total, refresh_time_seconds = 1, dismissable = false,
                }
            elseif stage == "part" then
                dialog:reportProgress(done_bytes)
            end
        end
    end)
end

local function confirmDownload(desktop, enable_after)
    UIManager:show(ConfirmBox:new{
        text = _("更新词库前，请先在“检查更新”中更新 Book 书库。新词库可能需要新版插件支持。是否继续？"),
        ok_text = _("继续下载"), ok_callback = function() download(desktop, enable_after) end,
    })
end

---@param desktop table
---@return table
function Language.rows(desktop)
    local lang = G_reader_settings:readSetting("language") or "C"
    local LanguageApi = require("ui/language")
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
                kind = "toggle", icon = "translate", title = _("拼音输入增强"),
                status = Pinyin.isEnabled() and _("开") or _("关"), status_on = Pinyin.isEnabled(),
                callback = function()
                    if not Pinyin.isEnabled() and not require("pinyin.dictionary").isAvailable() then
                        confirmDownload(desktop, true)
                        return
                    end
                    local on = Pinyin.setEnabled(not Pinyin.isEnabled())
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
                kind = "nav", icon = "spellcheck", title = _("拼音词库"),
                status = Pinyin.dictStatus(),
                status_on = require("pinyin.dictionary").isAvailable(),
                callback = function() confirmDownload(desktop) end,
            })
        end,
        function(iw)
            return hintRow(iw, T(_(
                "若在线下载过慢，可到 GitHub Release（%1）下载 pinyin-dictionary-版本号.sqlite3，"
                .. "重命名为 dictionary.sqlite3 后放入：\n%2"
            ), RELEASES_URL, Paths.pinyinDictPath()))
        end,
    }
end

return Language
