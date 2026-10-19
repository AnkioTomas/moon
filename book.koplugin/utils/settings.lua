--[[--
配置存储框架：只管分区文件、默认值、迁移与落盘，不认识任何具体设置项。

每个分区归一个拥有者，拥有者用模块路径标识（`reader`、`desktop.pages.home`、`features.nightmode`）：
  - 默认值声明在 `<拥有者>/setting.lua` 的 `defaults`，`keys` 列出无默认值但要持久的键；
    声明文件各侧都会加载（阅读器、离线测试），顶层别 require 界面模块。
  - 落盘到 settings/<路径末段>.lua；末段重名直接报错（与源配置 settings/<源 id>.lua 同目录，也别撞源 id）。
  - 读 `get(owner)`（返回表可就地改），写 `save(owner)`。
  - 每个进程首次打开时：先经 `utils.settings_legacy` 从拆分前的旧分区搬键（键名不变），再补默认值。

源 / 书城的独立配置走 getSource / saveSource（settings/<id>.lua，无默认值）。

@module koplugin.book.utils.settings
--]]

local LuaSettings = require("luasettings")
local Legacy = require("utils.settings_legacy")
local Paths = require("utils.paths")

local M = {}

local _files = {}
---@type table<string, string> 文件名 → 已打开它的拥有者
local _owners = {}
-- 拥有者 → LuaSettings：get 在绘制热路径上，不能每次拼路径。存文件对象而不是 data：save 可能 reset 换掉 data。
local _adopted = {}

--- 复制默认值，递归拷贝表，避免嵌套配置共享声明里的子表。
local function copyValue(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, nested in pairs(value) do out[key] = copyValue(nested) end
    return out
end

--- 就地补齐 data 里缺失的默认键；已有值（含 false）一律保留。
---@param data table 目标配置表（原地修改）
---@param defaults table|nil
---@return boolean dirty 是否补过键，调用方据此决定要不要 flush
local function fillDefaults(data, defaults)
    local dirty = false
    for key, value in pairs(defaults or {}) do
        if data[key] == nil then
            data[key] = copyValue(value)
            dirty = true
        end
    end
    return dirty
end

--- 按路径打开并缓存 LuaSettings 实例。
--- 同一路径全程复用一个实例：多份实例会各自持有 data 副本，flush 时互相覆盖。
---@param path string
---@return table LuaSettings
local function openFile(path)
    local ls = _files[path]
    if ls then return ls end
    Paths.ensureSettings()
    ls = LuaSettings:open(path)
    _files[path] = ls
    return ls
end

--- 首次打开：登记文件名归属，从旧分区搬键，补默认值。
---@param owner string
---@param name string 文件名（路径末段）
---@param file table LuaSettings
local function adopt(owner, name, file)
    _owners[name] = owner
    local spec = require(owner .. ".setting")
    local keys = {}
    for key in pairs(spec.defaults or {}) do keys[#keys + 1] = key end
    for _idx, key in ipairs(spec.keys or {}) do keys[#keys + 1] = key end
    local touched = Legacy.migrate(file, keys, openFile)
    if fillDefaults(file.data, spec.defaults) or #touched > 0 then file:flush() end
    for _idx, legacy in ipairs(touched) do legacy:flush() end
end

--- 某个拥有者的配置表（可就地修改，改完 save(owner) 落盘）。
---@param owner string 拥有者模块路径，声明在 `<owner>.setting`
---@return table
function M.get(owner)
    local cached = _adopted[owner]
    if cached then return cached.data end
    local name = owner:match("[^.]+$")
    local file = openFile(Paths.sectionPath(name))
    local current = _owners[name]
    if current and current ~= owner then
        error("settings file " .. name .. ".lua owned by both " .. current .. " and " .. owner)
    end
    if not current then adopt(owner, name, file) end
    _adopted[owner] = file
    return file.data
end

--- 落盘某个拥有者的配置。传入的表若不是 get 返回的那张，则整体 reset 覆盖（未出现的键被丢弃）。
---@param owner string
---@param values table|nil nil 表示只 flush 现有内容
function M.save(owner, values)
    local data = M.get(owner)
    local file = _adopted[owner]
    if values and values ~= data then file:reset(values) end
    file:flush()
end

--- 取某个源 / 书城的独立配置表 settings/<id>.lua（可就地修改，改完调 saveSource 落盘）。
---@param id string
---@return table
function M.getSource(id)
    return openFile(Paths.sourcePath(id)).data
end

--- 落盘某个源的配置。
--- 传入的表若不是 getSource 返回的那张，则整体 reset 覆盖（未出现的键被丢弃）。
---@param id string
---@param values table|nil nil 表示只 flush 现有内容
function M.saveSource(id, values)
    local file = openFile(Paths.sourcePath(id))
    if values and values ~= file.data then file:reset(values) end
    file:flush()
end

--- 磁盘上的配置被整体换掉后（恢复备份）：已打开的文件就地重读，持有旧引用的模块看到新值。
function M.reload()
    for path, file in pairs(_files) do
        local fresh = LuaSettings:open(path).data
        for key in pairs(file.data) do file.data[key] = nil end
        for key, value in pairs(fresh) do file.data[key] = value end
    end
end

return M
