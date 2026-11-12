--[[--
书摘分享入口：校验摘文后打开全屏编辑页。保存、分享都在编辑页里完成。

不强制把选区存成划线。不调用微信 API。

@module koplugin.book.features.share.dialog
--]]

require("l10n").apply()

local Toast = require("ui.themes.widgets.toast")
local _ = require("gettext")

local Dialog = {}

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
    local editor = Editor:new{
        payload = payload,
        state = Settings.read(),
    }
    editor:show()
end

return Dialog
