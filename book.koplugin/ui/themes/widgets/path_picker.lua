--[[--
主题路径选择器（替代 PathChooser）：全屏 List 逐层浏览目录，选文件或选文件夹。

  选文件夹（默认）                     选文件（select_file = true）
  +-------------------------------+    +-------------------------------+
  | [↑]     选择文件夹        [×] |    | [↑]      选择文件         [×] |   左键回上一级，到根目录不出现
  |         /mnt/us/books         |    |         /mnt/us/books         |   副标题：当前目录
  |-------------------------------|    |-------------------------------|
  | ✓ 选择此文件夹          books |    | 📁 科幻                       |
  | 📁 科幻                       |    | 📄 三体.epub                  |   path 指向的文件按选中样式画
  | 📁 历史                       |    | 🖼 封面.jpg                   |   图片文件（按后缀）画缩略图代替图标
  | [<]        1 / 2         [>]  |    | [<]        1 / 2         [>]  |
  +-------------------------------+    +-------------------------------+

点目录进入（不关窗）；点文件 / 「选择此文件夹」先关窗再 on_select(绝对路径)。
目录在前、文件在后，各自按名字（不分大小写）排序；隐藏项（. 开头）默认不列。
path 可以是目录或文件：文件时从所在目录开始；都不存在时逐级往上找，最终回落根目录。
读不了的目录（权限不足）显示为空，不报错。

  PathPicker:new{ path = "/mnt/us", on_select = function(dir) end }:show()
  PathPicker:new{ path = cur, select_file = true,
      filter = function(name) return name:match("%.epub$") ~= nil end,
      on_select = function(file) end }:show()

@module koplugin.book.ui.themes.widgets.path_picker
--]]

require("l10n").apply()

local lfs = require("libs/libkoreader-lfs")
local List = require("ui.themes.widgets.list")
local ImageFile = require("utils.image")
local _ = require("gettext")

local THUMB = 40 -- 缩略图边长（逻辑像素），Row 会再夹到行高内

---@class BookThemePathPicker : BookThemeList
---@field path string 起始路径（目录或文件），init 后是当前目录
---@field select_file boolean true 选文件，false 选文件夹
---@field filter fun(name: string): boolean|nil 文件名过滤（只作用于文件）
---@field show_hidden boolean
---@field on_select fun(path: string) 必填
local PathPicker = List:extend{
    path = "/",
    select_file = false,
    filter = nil,
    show_hidden = false,
}

---@param dir string
---@param name string
---@return string
local function join(dir, name)
    return dir == "/" and "/" .. name or dir .. "/" .. name
end

---@param path string
---@return string
local function parent(path)
    local up = path:match("^(.*)/[^/]*$")
    return (up == nil or up == "") and "/" or up
end

---@param path string
---@return string
local function basename(path)
    return path:match("([^/]+)$") or path
end

function PathPicker:init()
    local start = self.path:gsub("(.)/+$", "%1")
    if lfs.attributes(start, "mode") == "file" then self.picked = start end
    while lfs.attributes(start, "mode") ~= "directory" do start = parent(start) end
    self.path = start
    self.items = self:listing()
    self:decorate()
    List.init(self)
end

--- 当前目录的子目录与（选文件时）文件，排好序。
--- lfs.dir 对读不了的目录直接抛错：当作空目录，用户回上一级即可。
---@return string[] dirs
---@return string[] files
function PathPicker:scan()
    local dirs, files = {}, {}
    local ok, iter, state = pcall(lfs.dir, self.path)
    if not ok then return dirs, files end
    for name in iter, state do
        if name ~= "." and name ~= ".." and (self.show_hidden or name:sub(1, 1) ~= ".") then
            local mode = lfs.attributes(join(self.path, name), "mode")
            if mode == "directory" then
                dirs[#dirs + 1] = name
            elseif mode == "file" and self.select_file and (not self.filter or self.filter(name)) then
                files[#files + 1] = name
            end
        end
    end
    local function byName(a, b) return a:lower() < b:lower() end
    table.sort(dirs, byName)
    table.sort(files, byName)
    return dirs, files
end

---@return table[]
function PathPicker:listing()
    local items = {}
    if not self.select_file then
        items[1] = { text = _("选择此文件夹"), icon = "check", mandatory = basename(self.path),
            callback = function() self.on_select(self.path) end }
    end
    local dirs, files = self:scan()
    for _idx, name in ipairs(dirs) do
        local dir = join(self.path, name)
        items[#items + 1] = { text = name, icon = "folder", keep_open = true,
            callback = function() self:enter(dir) end }
    end
    for _idx, name in ipairs(files) do
        local file = join(self.path, name)
        local thumb = ImageFile.suffix(name) and file or nil
        items[#items + 1] = { text = name, icon = not thumb and "description" or nil,
            image = thumb, image_w = THUMB, image_h = THUMB, checked = file == self.picked or nil,
            callback = function() self.on_select(file) end }
    end
    return items
end

--- 标题栏随当前目录变：副标题是路径，根目录不出回上一级按钮。
function PathPicker:decorate()
    self.title = self.title or (self.select_file and _("选择文件") or _("选择文件夹"))
    self.subtitle = self.path
    self.left_icon = self.path ~= "/" and "arrow_upward" or nil
    self.left_callback = self.left_icon and function() self:enter(parent(self.path)) end or nil
end

---@param dir string
function PathPicker:enter(dir)
    self.path = dir
    self:decorate()
    self.items = self:listing()
    self.page = self:checkedPage()
    self:refresh()
end

return PathPicker
