--[[--
阅读页退出回月读桌面：关书后回桌面而不是 KOReader 原生文件管理器，并接管阅读菜单顶栏的文件浏览器图标。

接管挂在 `ReaderMenu:setUpdateItemTable`（各版本都有）：原函数跑完后，从重建好的
`tab_item_table` 里找 filemanager Tab 换回调。不要 patch `getDefaultMenuButtons`：它只有 nightly 有，
正式版 v2026.07 的按钮是 init 里内联写死的，patch 一个没人调用的方法等于没接管
（看书点抽屉先回原生文件管理器、在那边再点一次才回月读，就是这么来的）；也不要在原函数跑完后
找 `menu_items.filemanager`，它已被 MenuSorter 从 menu_items 里摘走置 nil。

@module koplugin.book.desktop.reader_exit
--]]

local UIManager = require("ui/uimanager")
local Perf = require("utils.perf")

local ReaderExit = {}

--- 只接原始返回按键；子模块先处理选区等状态，Back 动作与自定义手势仍走原生路径。
---@param ui table ReaderUI
function ReaderExit.attach(ui)
    if ui._book_back_attached then return end
    ui._book_back_attached = true
    for _idx, handler in ipairs({ "onKeyPress", "onKeyRepeat" }) do
        local original = ui[handler]
        ui[handler] = function(self, key)
            if require("utils.settings").get("reader").back_to_desktop == true
                and key:match({ require("device").input.group.Back }) then
                if not require("ui.input").isTop(self.dialog or self) then return false end
                if not self.link:isPageLinkSelected() then
                    if handler == "onKeyPress" then ReaderExit.closeToDesktop(self) end
                    return true
                end
            end
            return original(self, key)
        end
    end
end

--- 下一 tick 关闭文档并回到月读桌面（点击调用栈里不能同步关文档）。
---@param ui table|nil ReaderUI
function ReaderExit.closeToDesktop(ui)
    UIManager:nextTick(require("ui.guard").wrap("close to desktop", function()
        local started_at = Perf.now()
        if ui and ui.onClose then ui:onClose() end
        Perf.slow("exit onClose", started_at)
        -- 打开书时 ReaderUI 会关掉 FileManager；这里先重建，否则关闭文档后窗口栈为空直接退出。
        local Desktop = require("desktop")
        local fm = Desktop.ensureFileManager()
        Perf.slow("exit ensureFileManager", started_at)
        Desktop.open(fm.book)
        Perf.slow("exit total", started_at)
    end))
end

--- 启动项为月读且设置未关闭时，文件浏览器图标才改开月读桌面。
---@return boolean
function ReaderExit.drawerOpensDesktop()
    return require("menu").openOnStart() and require("utils.settings").get("desktop").drawer_opens_desktop == true
end

--- 一次性 patch ReaderMenu：每次重建菜单表后替换文件浏览器 Tab 的回调。
--- nightly 每次重建都换一张新 Tab 表（靠每次重打），正式版沿用同一张（靠 Tab 上的标记防叠包）。
function ReaderExit.install()
    local ReaderMenu = require("apps/reader/modules/readermenu")
    if ReaderMenu._book_drawer_patched then return end
    ReaderMenu._book_drawer_patched = true
    local original = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        local tab
        for _idx, item in ipairs(self.tab_item_table or {}) do
            if item.id == "filemanager" then
                tab = item
                break
            end
        end
        if not tab or tab._book_drawer_patched then return end
        tab._book_drawer_patched = true
        local native = tab.callback
        tab.callback = function()
            if not ReaderExit.drawerOpensDesktop() then return native() end
            self:onTapCloseMenu()
            ReaderExit.closeToDesktop(self.ui)
        end
    end
end

return ReaderExit
