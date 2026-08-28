--[[-- 阅读字体快捷动作。
@module koplugin.book.ui.panel.actions.reader.font
--]]

local UIManager = require("ui/uimanager")
local MoonFont = require("utils.font")
local T = require("ffi/util").template
local _ = require("gettext")

---@type BookQuickPanelAction
return {
    id = "font",
    title = _("阅读字体"),
    icon = "text_fields",
    scope = "reader",
    --- CRengine 文档支持 setFontFace 时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then
            return true
        end
        return MoonFont.supportsReader(ui)
    end,
    --- 打开 Book 字体选择器并应用到当前阅读文档。
    ---@param ctx BookQuickPanelContext
    ---@return void
    run = function(ctx)
        -- registry 会把所有动作模块一次性 require 进来：整棵 widget 树延迟到真正用时再拉
        local InfoMessage = require("ui/widget/infomessage")
        local FontPicker = require("ui.components.fontpicker")
        local ui = ctx.ui
        if not MoonFont.supportsReader(ui) then
            UIManager:show(InfoMessage:new{
                text = _("当前文档不支持字体与排版调整"),
            })
            return
        end
        FontPicker.open{
            title = _("阅读字体"),
            current_id = function()
                return MoonFont.readerCurrentId(ui)
            end,
            on_select = function(_item, id, name)
                local ok, err = MoonFont.applyToReader(ui, id, name)
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("已选择：%1"), name),
                        timeout = 2,
                    })
                else
                    UIManager:show(InfoMessage:new{ text = err or _("应用字体失败") })
                end
            end,
        }
    end,
}
