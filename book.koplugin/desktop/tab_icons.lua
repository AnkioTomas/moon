--[[--
底栏页签自定义图标：长按页签（内置与拓展），从文件里选一张图片代替字体图标。

选中的图片缩成 SIZE 像素内的 PNG，落到 `$DATA/.moon/tab_icons/<页签>-<时间>.png`，
设置 `desktop.tab_icons[页签]` 记路径；文件名带时间，换图不会命中 KOReader 按文件名的位图缓存。
文件丢了就回落字体图标。

@module koplugin.book.desktop.tab_icons
--]]

local lfs = require("libs/libkoreader-lfs")
local MoonSettings = require("utils.settings")
local Image = require("utils.image")
local Paths = require("utils.paths")
local _ = require("gettext")

local TabIcons = {}

local SIZE = 128

--- 自定义图标文件；没设置或文件已丢返回 nil。
---@param id string
---@return string|nil
function TabIcons.file(id)
    local path = MoonSettings.get("desktop").tab_icons[id]
    if path and lfs.attributes(path, "mode") == "file" then return path end
end

--- 缩成小 PNG 存进数据目录，换掉旧文件。解不开返回 nil。
---@param id string
---@param src string
---@return string|nil dest
local function store(id, src)
    local img = require("ui/widget/imagewidget"):new{
        file = src, width = SIZE, height = SIZE, scale_factor = 0, alpha = true, file_do_cache = false,
    }
    local ok, bb = pcall(function()
        img:getSize()
        return img._bb
    end)
    if not (ok and bb) then
        img:free()
        return nil
    end
    local dir = Paths.root() .. "/tab_icons"
    Paths.ensureDir(dir)
    local dest = string.format("%s/%s-%d.png", dir, id:gsub("[^%w_]", "_"), os.time())
    local wrote = pcall(function() bb:writePNG(dest) end)
    img:free()
    if not wrote then
        os.remove(dest)
        return nil
    end
    return dest
end

--- 写设置并删掉被换下的旧文件。
---@param id string
---@param dest string|nil nil = 恢复默认
local function assign(id, dest)
    local icons = MoonSettings.get("desktop").tab_icons
    local old = icons[id]
    icons[id] = dest
    MoonSettings.save("desktop")
    if old and old ~= dest then os.remove(old) end
end

---@param desktop BookDesktop
---@param id string
local function pick(desktop, id)
    require("ui.themes.widgets.path_picker"):new{
        path = require("apps/filemanager/filemanagerutil").getHomeFolder(),
        select_file = true,
        filter = function(name) return Image.suffix(name) ~= nil end,
        on_select = function(path)
            local dest = store(id, path)
            if not dest then
                require("ui.themes.widgets.toast"):new{ text = _("无法读取这张图片"), timeout = 3 }:show()
                return
            end
            assign(id, dest)
            desktop:updateView()
        end,
    }:show()
end

--- 长按页签弹出：选图片 / 恢复默认。
---@param desktop BookDesktop
---@param tab table 页签（id / text）
function TabIcons.menu(desktop, tab)
    local items = { { text = _("选择图片"), callback = function() pick(desktop, tab.id) end } }
    if TabIcons.file(tab.id) then
        items[#items + 1] = {
            text = _("恢复默认图标"),
            callback = function()
                assign(tab.id, nil)
                desktop:updateView()
            end,
        }
    end
    require("ui.themes.widgets.sheet"):new{ title = tab.text, items = items }:show()
end

return TabIcons
