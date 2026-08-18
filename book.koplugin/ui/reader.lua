--[[--
阅读控制台：用上下边缘点按唤出 Kindle 风格的顶部与底部操作栏。

正文不再有插件中间点按区；控制台未显示时，正文点按仍完全交给
KOReader 的翻页手势。活跃 Book 阅读会话之外不接管任何输入。

@module koplugin.book.ui.reader
--]]

local UIManager = require("ui/uimanager")

local Reader = {
    ---@type table|nil
    _toolbar = nil,
}

---@return boolean
function Reader.isToolbarOpen()
    return Reader._toolbar ~= nil
end

---@param plugin table
function Reader.showToolbar(plugin)
    if Reader._toolbar then
        return
    end
    local toolbar = require("ui.reader.panel"):new{
        plugin = plugin,
        close_callback = function()
            Reader._toolbar = nil
            Reader.refresh(plugin)
        end,
    }
    Reader._toolbar = toolbar
    UIManager:show(toolbar)
    Reader.refresh(plugin)
end

---@return nil
function Reader.closeToolbar()
    if Reader._toolbar then
        UIManager:close(Reader._toolbar)
        Reader._toolbar = nil
    end
end

--- 给当前 ReaderUI 装上下边缘点按与常驻阅读状态条。
---@param plugin table
function Reader.attach(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then
        return
    end
    ui._book_reader_attached = true

    if ui.registerTouchZones then
        local overrides = {
            "tap_forward", "tap_backward",
            "readermenu_tap", "readermenu_ext_tap",
            "readerconfigmenu_tap", "readerconfigmenu_ext_tap",
        }
        ui:registerTouchZones({
            {
                id = "book_reader_top_tap",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.15 },
                overrides = overrides,
                handler = function()
                    if not require("ui.reader.session").isActive() then
                        return false
                    end
                    Reader.showToolbar(plugin)
                    return true
                end,
            },
            {
                id = "book_reader_bottom_tap",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0.85, ratio_w = 1, ratio_h = 0.15 },
                overrides = overrides,
                handler = function()
                    if not require("ui.reader.session").isActive() then
                        return false
                    end
                    Reader.showToolbar(plugin)
                    return true
                end,
            },
        })
    end
    if ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("book_bars", require("ui.reader.bars"))
        require("ui.reader.bars").startClock()
    end
    require("lockscreen.init").refreshInBackground()
end

---@param plugin table
function Reader.refresh(plugin)
    local ui = plugin and plugin.ui
    if ui then
        UIManager:setDirty(ui.dialog, "ui")
    end
    require("lockscreen.init").refreshInBackground()
end

return Reader
