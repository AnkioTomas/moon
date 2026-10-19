--[[--
阅读页退出回月读桌面：关书后回桌面而不是 KOReader 原生文件管理器，并接管阅读菜单顶栏的文件浏览器图标。

接管在类级别装一次（main init 调 `install`），要早于任何 ReaderMenu 实例：ReaderMenu 在 init 里就调
`getDefaultMenuButtons` 固化按钮，晚装会让第一次阅读的图标仍走原生文件管理器。

@module koplugin.book.desktop.reader_exit
--]]

local UIManager = require("ui/uimanager")

local ReaderExit = {}

--- 下一 tick 关闭文档并回到月读桌面（点击调用栈里不能同步关文档）。
---@param ui table|nil ReaderUI
function ReaderExit.closeToDesktop(ui)
    UIManager:nextTick(require("ui.guard").wrap("close to desktop", function()
        if ui and ui.onClose then ui:onClose() end
        local FileManager = require("apps/filemanager/filemanager")
        -- 打开书时 ReaderUI 会关掉 FileManager；这里先重建，否则关闭文档后窗口栈为空直接退出。
        if not FileManager.instance then FileManager:showFiles() end
        require("desktop").open(FileManager.instance.book)
    end))
end

--- 启动项为月读且设置未关闭时，文件浏览器图标才改开月读桌面。
---@return boolean
function ReaderExit.drawerOpensDesktop()
    return require("menu").openOnStart() and require("utils.settings").get("desktop").drawer_opens_desktop == true
end

--- 一次性 patch ReaderMenu 的文件浏览器按钮。
function ReaderExit.install()
    local ReaderMenu = require("apps/reader/modules/readermenu")
    if ReaderMenu._book_drawer_patched then return end
    ReaderMenu._book_drawer_patched = true
    local original = ReaderMenu.getDefaultMenuButtons
    ReaderMenu.getDefaultMenuButtons = function(self)
        local buttons = original(self)
        local fm = buttons.filemanager
        local native = fm.callback
        fm.callback = function()
            if not ReaderExit.drawerOpensDesktop() then return native() end
            self:onTapCloseMenu()
            ReaderExit.closeToDesktop(self.ui)
        end
        return buttons
    end
end

return ReaderExit
