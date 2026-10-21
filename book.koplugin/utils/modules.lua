--[[--
插件模块的直达加载器。

KOReader 加载完插件后把每个插件目录追加到 package.path 末尾，之后插件的懒加载 `require`
要先把 KOReader 与全部其它插件的路径逐个 open 失败一遍才轮到本插件；`?/init.lua` 条目更是排在最后。
Kindle 的 /mnt/us 元数据很慢，几百个模块乘几十次失败 open，就是启动慢、更新后首次启动更慢的来源
（目录项缓存是冷的）。这里扫一遍插件目录建「模块名 → 文件」表，登记成 package.loaders 的第二项，
命中的模块一次 loadfile 直达；表里没有的（KOReader 自己的模块）照旧走标准搜索。

插件模块名与 KOReader 的模块名没有交集（点号写法 `ui.themes` 与 KOReader 的 `ui/widget/x` 路径互不重名）。

@module koplugin.book.utils.modules
--]]

local lfs = require("libs/libkoreader-lfs")

local Modules = {}

local installed = {}

--- 递归登记 dir 下的 .lua：`a/b.lua` → "a/b"，`a/init.lua` → "a"；同名时 `a.lua` 优先于 `a/init.lua`，与 `?.lua;?/init.lua` 的顺序一致。
---@param dir string 绝对路径
---@param prefix string 模块名前缀（含结尾斜杠，根目录为 ""）
---@param index table<string, string>
local function scan(dir, prefix, index)
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        if name:sub(1, 1) == "." then
            -- 跳过 . / .. / 隐藏项
        elseif lfs.attributes(path, "mode") == "directory" then
            scan(path, prefix .. name .. "/", index)
        elseif name == "init.lua" and prefix ~= "" then
            local key = prefix:sub(1, -2)
            index[key] = index[key] or path
        elseif name:sub(-4) == ".lua" then
            index[prefix .. name:sub(1, -5)] = path
        end
    end
end

--- 扫描插件目录并登记加载器（同一目录只装一次）。
---@param root string 插件根目录
---@return table<string, string> index 模块路径（斜杠写法）→ 文件
function Modules.install(root)
    if installed[root] then return installed[root] end
    local index = {}
    scan(root, "", index)
    -- 插件入口与元数据不是可 require 的模块；入口 `main` 这种通用名不能抢别的插件的。
    index.main = nil
    index._meta = nil
    installed[root] = index
    table.insert(package.loaders, 2, function(name)
        local path = index[name:gsub("%.", "/")]
        if not path then return nil end
        return assert(loadfile(path))
    end)
    return index
end

return Modules
