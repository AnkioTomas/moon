--[[--
第三方扩展（KOReader 插件 moon_source.lua 的 `provides.features`）挂点收集与隔离工具。

核心收集点（设置树、桌面顶栏）与 features 层（快捷面板注册表、数据事件）共用；本模块不认识任何内置 feature。
形状与规则见 features/init.lua 文首「第三方 feature」一节。

@module koplugin.book.utils.external
--]]

local logger = require("utils.log")

local External = {}

local function settle(label, ok, ...)
    if ok then return ... end
    logger.err("feature external failed", label, (...))
end

--- 跑一个第三方回调：出错只记日志并返回 nil。
---@param label string
---@param fn function
function External.try(label, fn, ...)
    if type(fn) ~= "function" then return end
    return settle(label, pcall(fn, ...))
end

--- 把第三方回调包成隔离版本；不是函数原样返回（nil 仍是 nil）。
---@param label string
---@param fn any
function External.wrap(label, fn)
    if type(fn) ~= "function" then return fn end
    return function(...) return External.try(label, fn, ...) end
end

--- 给第三方项 id 加 `<扩展 id>.` 前缀；不是非空字符串返回 nil。
---@param ext_id string
---@param id any
---@return string|nil
function External.prefix(ext_id, id)
    if type(id) ~= "string" or id == "" then return nil end
    if id:sub(1, #ext_id + 1) == ext_id .. "." then return id end
    return ext_id .. "." .. id
end

--- 第三方扩展声明的某类 feature 挂点，按插件加载顺序：{ id = 扩展 id, mod = 解析后的表 }。
--- 模块名在这里 require，失败记日志跳过。不缓存；第二返回值为假表示插件还没加载完，调用方别缓存结果。
---@param kind "setting"|"panel"|"topbar"|"events"|"hooks"
---@return { id: string, mod: table }[] items, boolean ready
function External.collect(kind)
    local out = {}
    -- 拿不到注册表（离线测试没有 pluginloader 等）就当没有第三方扩展。
    local ok, Registry = pcall(require, "source.registry")
    local exts = ok and External.try("source.registry extensions", Registry.extensions)
    if type(exts) ~= "table" then return out, true end
    for _idx, ext in ipairs(exts) do
        local spec = ext.features and ext.features[kind]
        if spec ~= nil then
            local mod = type(spec) == "string" and External.try(ext.id .. " " .. kind, require, spec) or spec
            if type(mod) == "table" then
                out[#out + 1] = { id = ext.id, mod = mod }
            else
                logger.err("feature external rejected", ext.id, kind)
            end
        end
    end
    return out, Registry.extensionsReady()
end

return External
