--[[--
输入后端装载：按平台 require Android / 桌面后端，缺失时返回不可用后端。

后端契约（ticket 08 / 09 实现）：
  available(): boolean
  show(vk)
  hide(vk)
  status(): "ready" | "not_ready" | "unavailable"
  test()        可选，桌面 / WSL 的手动测试入口

后端不直接改全局设置，也不包装 VirtualKeyboard；路由与互斥由 features.ime 负责。

@module koplugin.book.features.ime.backend
--]]

local Backend = {}

--- 不可用后端：所有调用安全无操作，供模块缺失 / 墨水屏 / 未实现平台使用。
---@param name string|nil
---@return table
function Backend.unavailable(name)
    return {
        name = name or "none",
        available = function() return false end,
        show = function() end,
        hide = function() end,
        status = function() return "unavailable" end,
    }
end

--- 安全调用可选后端方法：后端抛错时按不可用处理，不让一次输入拖垮界面。
---@param fn function|nil
---@param fallback any
---@return function
local function safe(fn, fallback)
    if type(fn) ~= "function" then
        return function() return fallback end
    end
    return function(...)
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return fallback
    end
end

--- 按模块名装在输入后端；模块不存在、加载失败或形状不对时降级为不可用。
---@param name string|nil 如 "features.system_ime" / "features.system_text"
---@return table
function Backend.load(name)
    if type(name) ~= "string" or name == "" then
        return Backend.unavailable()
    end
    local ok, mod = pcall(require, name)
    if not ok or type(mod) ~= "table" then
        return Backend.unavailable(name)
    end
    local available = safe(mod.available, false)
    return {
        name = name,
        available = available,
        -- show 抛错时返回 false，让路由回退到原生键盘，而不是静默留下空屏。
        show = safe(mod.show, false),
        hide = safe(mod.hide, nil),
        -- 复位未提交的系统输入法组合串；后端不支持时保持 nil。
        reset = type(mod.reset) == "function" and safe(mod.reset, nil) or nil,
        status = safe(mod.status, available() and "ready" or "unavailable"),
        test = type(mod.test) == "function" and function(...)
            local ok_test, value = pcall(mod.test, ...)
            if ok_test then return value end
        end or nil,
    }
end

return Backend
