--[[-- 阅读字体快捷动作。
@module koplugin.book.features.panel.actions.reader.font
--]]

local FontReader = require("ui.fonts.reader")
local T = require("ffi/util").template
local _ = require("gettext")

--- 阅读字体选择器参数：勾选当前文档字体，选中即应用到当前阅读文档（阅读页侧栏共用）。
---@param ui table ReaderUI
---@return FontPickerOpts
local function pickerOpts(ui)
    return {
        title = require("utils.settings").get("reader").mixed_fonts and _("中文字体") or _("阅读字体"),
        current_id = function()
            return FontReader.currentId(ui)
        end,
        on_select = function(_item, id, name)
            local ok, err = FontReader.apply(ui, id, name)
            if ok then
                require("reader.prefs").captureAndSave(ui)
                require("ui.themes.widgets.toast"):new{
                    text = T(_("已选择：%1"), name),
                    timeout = 2,
                }:show()
            else
                require("ui.themes.widgets.toast"):new{ text = err or _("应用字体失败") }:show()
            end
        end,
    }
end

---@type BookQuickPanelAction
return {
    id = "font",
    title = _("阅读字体"),
    icon = "text_fields",
    scope = "reader",
    pickerOpts = pickerOpts,
    --- CRengine 文档支持 setFontFace 时显示。
    ---@param ctx BookQuickPanelContext|nil
    ---@return boolean
    available = function(ctx)
        local ui = ctx and ctx.ui
        if not ui then
            return true
        end
        return FontReader.supports(ui)
    end,
    --- 打开 Book 字体选择器并应用到当前阅读文档。
    ---@param ctx BookQuickPanelContext
    run = function(ctx)
        -- registry 会把所有动作模块一次性 require 进来：整棵 widget 树延迟到真正用时再拉
        local FontPicker = require("ui.widgets.fontpicker")
        local ui = ctx.ui
        if not FontReader.supports(ui) then
            require("ui.themes.widgets.toast"):new{
                text = _("当前文档不支持字体与排版调整"),
            }:show()
            return
        end
        if not require("utils.settings").get("reader").mixed_fonts then
            FontPicker.open(pickerOpts(ui))
            return
        end
        require("ui.themes.widgets.sheet"):new{
            title = _("阅读字体"),
            items = {
                { text = _("中文字体"), callback = function() FontPicker.open(pickerOpts(ui)) end },
                { text = _("西文字体"), callback = function() FontPicker.open(FontReader.westernPickerOpts(ui)) end },
            },
        }:show()
    end,
}
