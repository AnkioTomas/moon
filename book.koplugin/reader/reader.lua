--[[--
阅读页管理器：注入中间点按面板与上下进度条，驱动阅读期 UI 刷新。

attach 幂等：tap zone 与 view module 常驻 ReaderUI 实例；
无身份文档（Session 不活跃）时点按自动放行翻页、进度条不绘制，无需 detach。

@module koplugin.book.reader.reader
--]]

local UIManager = require("ui/uimanager")

local Reader = {
    ---@type table|nil 当前打开的阅读面板
    _panel = nil,
}

--- 给当前 ReaderUI 装中间点按与进度条（每个 ReaderUI 实例只装一次）。
---@param plugin table
---@return nil
function Reader.attach(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then
        return
    end
    ui._book_reader_attached = true

    if ui.registerTouchZones then
        ui:registerTouchZones({
            {
                id = "book_center_tap",
                ges = "tap",
                screen_zone = { ratio_x = 1 / 4, ratio_y = 1 / 4, ratio_w = 1 / 2, ratio_h = 1 / 2 },
                overrides = { "tap_forward", "tap_backward" },
                handler = function()
                    if not require("reader.session").isActive() then
                        return false -- 落回默认翻页
                    end
                    Reader.showPanel(plugin)
                    return true
                end,
            },
        })
    end
    if ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("book_bars", require("reader.bars"))
        require("reader.bars").startClock()
    end
end

--- 打开阅读面板（详情 / 目录 / 视觉）；重复打开先关旧实例。
---@param plugin table
---@return nil
function Reader.showPanel(plugin)
    if Reader._panel then
        UIManager:close(Reader._panel)
        Reader._panel = nil
    end
    local panel = require("reader.panel"):new{
        plugin = plugin,
        close_callback = function()
            Reader._panel = nil
        end,
    }
    Reader._panel = panel
    UIManager:show(panel)
end

--- 请求阅读页重绘（进度条在 view_modules 绘制链里自动重画）。
---@param plugin table
---@return nil
function Reader.refresh(plugin)
    local ui = plugin and plugin.ui
    if ui then
        UIManager:setDirty(ui.dialog, "ui")
    end
end

return Reader
