--[[--
书摘分享入口：校验摘文后打开全屏编辑页。保存、分享都在编辑页里完成。

不强制把选区存成划线。不调用微信 API。

@module koplugin.book.features.share.dialog
--]]

require("l10n").apply()

local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")

local Dialog = {}

--- 进程内缓存上次选项；真正的来源是 features.share.settings（落盘）。
Dialog.last = {
    theme = "calendar",
    font = "song",
    swatch = "default",
    art = "sunset",
    show_logo = true,
}

--- 打开书摘编辑页。
---@param payload table
function Dialog.open(payload)
    if type(payload) ~= "table" or type(payload.text) ~= "string" or payload.text:match("%S") == nil then
        Toast:new{ text = _("没有可摘录的文字"), timeout = 2 }:show()
        return
    end
    payload.text = require("utils.text").trim(payload.text)
    local Editor = require("features.share.editor")
    local Settings = require("features.share.settings")
    local state = Editor.mergeState(Settings.read())
    Dialog.last = state
    local editor
    editor = Editor:new{
        payload = payload,
        state = state,
        close_callback = function()
            if editor and editor.state then
                Dialog.last = Editor.mergeState(editor.state)
                Settings.write(Dialog.last)
            end
        end,
    }
    editor:show()
end

return Dialog
