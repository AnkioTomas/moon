--[[--
精简功能：用户可以把不用的 feature 整个目录删掉，减小体积与内存占用。

只允许删 `ITEMS` 里的 feature（没有被别的 feature 引用、核心也不依赖它们）。设置里只记「要删谁」
（`features.manage.removed`），真正的删除发生在下次启动加载器之前：当前进程里已加载的模块还要用到
自己的文件，不能当场删。记录一直保留，所以更新月读把目录装回来后下次启动会再删一次；
在设置页取消记录再更新月读即可找回。

@module koplugin.book.features.manage
--]]

require("l10n").apply()
local _ = require("gettext")

local Manage = {}

---@class BookRemovableFeature
---@field id string features 下的目录名
---@field label string
---@field subtitle string

---@type BookRemovableFeature[]
Manage.ITEMS = {
    { id = "animation", label = _("翻页动画"), subtitle = _("需要给 KOReader 打补丁") },
    { id = "azw3", label = _("AZW3 支持"), subtitle = _("打开 AZW3 / KF8 书籍") },
    { id = "bars", label = _("阅读状态栏"), subtitle = _("阅读页上下进度条") },
    { id = "bluetooth", label = _("蓝牙"), subtitle = _("联动蓝牙守护进程") },
    { id = "cookie", label = _("Cookie 存储"), subtitle = _("接收浏览器扩展同步的 Cookie") },
    { id = "extensions", label = _("拓展页签"), subtitle = _("桌面底栏的其它插件入口") },
    { id = "keyboard", label = _("键盘增强"), subtitle = _("虚拟键盘的收起键") },
    { id = "nightmode", label = _("自动夜间与亮度"), subtitle = _("按时间或天气调整") },
    { id = "ocr", label = _("OCR 识字"), subtitle = _("图片文字识别") },
    { id = "reviews", label = _("他人段评"), subtitle = _("页内显示微信读书段评") },
    { id = "sidebar", label = _("阅读侧栏"), subtitle = _("阅读页右滑打开") },
    { id = "storage", label = _("存储空间"), subtitle = _("占用查看与清理") },
    { id = "wallpaper", label = _("壁纸"), subtitle = _("每日壁纸") },
}

---@param id string
---@return boolean
local function removable(id)
    for _idx, item in ipairs(Manage.ITEMS) do
        if item.id == id then return true end
    end
    return false
end

---@return string[]
local function marked()
    return require("utils.settings").get("features.manage").removed
end

---@param id string
---@return boolean
function Manage.isMarked(id)
    for _idx, name in ipairs(marked()) do
        if name == id then return true end
    end
    return false
end

--- 目录是否还在（已被启动时的清理删掉就是 false）。
---@param dir string features 目录
---@param id string
---@return boolean
function Manage.exists(dir, id)
    return require("libs/libkoreader-lfs").attributes(dir .. "/" .. id, "mode") == "directory"
end

--- 标记 / 取消标记；返回现在是否已标记。
---@param id string
---@return boolean
function Manage.toggle(id)
    local MoonSettings = require("utils.settings")
    local s = MoonSettings.get("features.manage")
    for idx, name in ipairs(s.removed) do
        if name == id then
            table.remove(s.removed, idx)
            MoonSettings.save("features.manage", s)
            return false
        end
    end
    s.removed[#s.removed + 1] = id
    MoonSettings.save("features.manage", s)
    return true
end

--- 加载器在 require 任何 feature 之前调：删掉已标记的目录，并把它们从 list 里去掉。
---@param dir string features 目录
---@param list string[] Features.list（就地修改）
function Manage.purge(dir, list)
    for _idx, id in ipairs(marked()) do
        if removable(id) then
            if Manage.exists(dir, id) then require("ffi/util").purgeDir(dir .. "/" .. id) end
            for i = #list, 1, -1 do
                if list[i] == id then table.remove(list, i) end
            end
        end
    end
end

return Manage
