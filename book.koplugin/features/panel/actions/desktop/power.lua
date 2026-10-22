--[[-- 电源快捷动作：退出月读、退出 KOReader、重启、休眠、重启设备。
设备不支持的项不显示。退出 KOReader / 重启走 KOReader 自己的 Exit / Restart，不另写退出流程。
@module koplugin.book.features.panel.actions.desktop.power
--]]

local Device = require("device")
local _ = require("gettext")

--- 关掉还开着的月读桌面。桌面留在窗口栈上时，KOReader 的 Exit 关了文件管理器也不会退出。
local function closeDesktop()
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.book
    local desktop = plugin and plugin.desktop
    if desktop and not desktop.closed then desktop:onClose() end
end

--- 退出月读，留在 KOReader。阅读中先重建文件管理器再关书，否则空窗口栈会把 KOReader 也退出。
---@param ctx BookQuickPanelContext
local function exitMoon(ctx)
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local ui = ctx and ctx.ui
        local plugin = ui and ui.book
        if not plugin then
            local FileManager = require("apps/filemanager/filemanager")
            plugin = FileManager.instance and FileManager.instance.book
        end
        local desktop = plugin and plugin.desktop
        if desktop and not desktop.closed then
            desktop:onClose()
            return
        end
        local reader = (ui and ui.document and ui) or (plugin and plugin.ui)
        if not (reader and reader.document and reader.onClose) then return end
        require("desktop").ensureFileManager()
        reader:onClose()
    end)
end

local function show(ctx)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local items = {
        { text = _("退出月读"), callback = function() exitMoon(ctx) end },
        { text = _("退出 KOReader"), callback = function()
            closeDesktop()
            UIManager:broadcastEvent(Event:new("Exit"))
        end },
    }
    if Device:canRestart() then
        items[#items + 1] = { text = _("重启 KOReader"), callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end }
    end
    if Device:canSuspend() then
        items[#items + 1] = { text = _("休眠"), callback = function()
            UIManager:suspend()
        end }
    end
    if Device:canReboot() then
        items[#items + 1] = { text = _("重启设备"), callback = function()
            UIManager:askForReboot()
        end }
    end
    require("ui.themes.widgets.sheet"):new{ title = _("电源"), items = items }:show()
end

---@type BookQuickPanelAction
return {
    id = "power",
    title = _("电源"),
    icon = "power",
    scope = "desktop",
    run = function(ctx) show(ctx) end,
}
