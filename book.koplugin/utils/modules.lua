--[[--
插件模块的直达加载器。

KOReader 加载完插件后把每个插件目录追加到 package.path 末尾，之后插件的懒加载 `require`
要先把 KOReader 与全部其它插件的路径逐个 open 失败一遍才轮到本插件；`?/init.lua` 条目更是排在最后。
Kindle 的 /mnt/us 元数据很慢，几百个模块乘几十次失败 open，就是启动慢、更新后首次启动更慢的来源
（目录项缓存是冷的）。这里扫一遍插件目录建「模块名 → 文件」表，登记成 package.loaders 的第二项，
命中的模块一次 loadfile 直达；表里没有的（KOReader 自己的模块）照旧走标准搜索。

插件模块名与 KOReader 的模块名没有交集（点号写法 `ui.themes` 与 KOReader 的 `ui/widget/x` 路径互不重名）。

同名污染：别的 `.koplugin` 若也有顶层 `desktop/` / `utils/` 等，并抢先 `require`，会把错模块写进
`package.loaded`。Lua 的 require 在调用 loader 之前就短路返回缓存，本加载器根本没机会纠正。
因此对本插件目录内发起的、且属于本插件的模块名，绕过被污染的 `package.loaded`，始终加载本目录文件。

@module koplugin.book.utils.modules
--]]

local lfs = require("libs/libkoreader-lfs")

local Modules = {}

local installed = {}
--- root → { [modname] = module }：本插件权威缓存，不被别人的 package.loaded 带跑。
local loaded_by_root = {}

--- 递归登记 dir 下的 .lua：`a/b.lua` → "a/b"，`a/init.lua` → "a"；同名时 `a/init.lua` 优先于 `a.lua`：
--- 仓库里不会同时存在两者，同时出现只能是覆盖解压留下的旧版 `a.lua`（模块后来改成了目录），让它赢就会加载旧代码。
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
            index[key] = path
        elseif name:sub(-4) == ".lua" then
            local key = prefix .. name:sub(1, -5)
            local known = index[key]
            if not (known and known:sub(-9) == "/init.lua") then index[key] = path end
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
    local ours = {}
    loaded_by_root[root] = ours

    -- 只服务本插件目录内发起的 require：别的 koplugin 撞名的 utils/、ui/ 不能被劫持到这里的代码。
    -- 栈：1 本加载器，2 require（C），3 发起 require 的 chunk。`return require(x)` 是尾调用，发起方帧被抹掉，
    -- 这时看到的是再上一层；认不出来只是退回标准搜索（慢），不会装错模块。
    local mine = "@" .. root .. "/"
    table.insert(package.loaders, 2, function(name)
        local path = index[name:gsub("%.", "/")]
        if not path then return nil end
        local caller = debug.getinfo(3, "S")
        if not (caller and caller.source:sub(1, #mine) == mine) then return nil end
        return assert(loadfile(path))
    end)

    -- 别的插件抢先 require 同名模块后，package.loaded 会挡住所有 loader。
    -- 只服务本插件目录内的调用方：有权威缓存就强制写回，没有就 loadfile。
    -- `return require(x)` 尾调用会抹掉发起方栈帧，认不出时退回标准 require（与 loader 同一约定）。
    local real_require = require
    _G.require = function(name)
        -- 已加载且没被别人顶掉：结果与标准 require 相同，省掉每次的 gsub + debug.getinfo。
        local cached = ours[name]
        if cached ~= nil and package.loaded[name] == cached then return cached end
        local path = index[name:gsub("%.", "/")]
        if not path then return real_require(name) end
        local caller = debug.getinfo(2, "S")
        if not (caller and caller.source:sub(1, #mine) == mine) then
            return real_require(name)
        end
        if cached ~= nil then
            package.loaded[name] = cached
            return cached
        end
        -- 与 Lua require 一致：先占位，环依赖时拿到 true / 半成品而不是再次进入。
        package.loaded[name] = true
        local mod = assert(loadfile(path))(name)
        if mod == nil then mod = true end
        package.loaded[name] = mod
        ours[name] = mod
        return mod
    end

    -- 启动瞬间清掉已被别人写进 package.loaded 的同名项，避免 main.lua 后续 require 拿到脏缓存。
    for key in pairs(index) do
        package.loaded[key:gsub("/", ".")] = nil
    end

    return index
end

--- 插件目录被整体替换后（在线更新装好、尚未重启）重建索引。
--- 已装过的仍复用同一个 loader 闭包：它读的是 installed[root] 表，原地换表即可。
---@param root string
---@return table<string, string>
function Modules.refresh(root)
    local index = {}
    scan(root, "", index)
    index.main = nil
    index._meta = nil
    local ours = loaded_by_root[root]
    if ours then
        for key in pairs(ours) do ours[key] = nil end
    end
    if installed[root] then
        local old = installed[root]
        for key in pairs(old) do
            package.loaded[key:gsub("/", ".")] = nil
            old[key] = nil
        end
        for key, path in pairs(index) do old[key] = path end
        return old
    end
    return Modules.install(root)
end

return Modules
