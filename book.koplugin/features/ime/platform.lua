--[[--
输入法平台判定：决定默认输入方式与后端模块，不碰界面。

`detect(device, env, os_name)` 是纯函数，便于在 Android / 桌面 / WSL / 墨水屏
四种判定下重放；`current()` 才读真实 Device 与进程环境。

@module koplugin.book.features.ime.platform
--]]

local Platform = {}

local function has(device, method)
    local fn = device and device[method]
    if type(fn) ~= "function" then
        return false
    end
    local ok, value = pcall(fn, device)
    return ok and value == true
end

local function isWSL(env)
    env = env or os
    local getenv = env.getenv
    if type(getenv) ~= "function" then
        return false
    end
    return (getenv("WSL_DISTRO_NAME") or "") ~= ""
        or (getenv("WSL_INTEROP") or "") ~= ""
end

--- 读内核版本；WSL2 的 osrelease 形如 `6.6.114.1-microsoft-standard-WSL2`。
---@return string|nil
local function osrelease()
    local fh = io.open("/proc/sys/kernel/osrelease", "r")
    if not fh then return nil end
    local value = fh:read("*l")
    fh:close()
    return value
end

--- 当前是否运行在 WSL 内。
--- 显式 env（测试 / 注入）只认环境变量；真实环境额外用 osrelease 兜底，
--- 避免 WSL_DISTRO_NAME 未导出的 shell 被当成原生 Linux。
---@param env table|nil 提供 getenv 的对象（默认 os）
---@param release string|nil /proc/sys/kernel/osrelease 内容（测试可注入）
---@return boolean
function Platform.isWSL(env, release)
    env = env or os
    if isWSL(env) then return true end
    if release == nil and env == os then
        release = osrelease()
    end
    return type(release) == "string"
        and release:lower():find("microsoft", 1, true) ~= nil
end

--- 当前平台标识。
---@param device table|nil Device 实例（测试可给假设备）
---@param env table|nil 提供 getenv 的对象（默认 os）
---@param os_name string|nil ffi.os 值（默认读真实 ffi.os）
---@param release string|nil /proc/sys/kernel/osrelease 内容（测试可注入）
---@return "android"|"windows"|"macos"|"linux"|"wsl"|"kindle"|"kobo"|"pocketbook"
function Platform.detect(device, env, os_name, release)
    if has(device, "isKindle") then return "kindle" end
    if has(device, "isKobo") then return "kobo" end
    if has(device, "isPocketBook") then return "pocketbook" end
    if has(device, "isAndroid") then return "android" end
    os_name = os_name or (pcall(require, "ffi") and require("ffi").os)
    if os_name == "Windows" then return "windows" end
    if os_name == "OSX" then return "macos" end
    if Platform.isWSL(env, release) then return "wsl" end
    return "linux"
end

--- 墨水屏无条件使用内置键盘。
---@param device table|nil
---@return boolean
function Platform.isEink(device)
    return has(device, "hasEinkScreen")
end

--- 平台默认输入方式；nil / 未知平台按内置键盘处理。
---@param platform string|nil
---@return "system"|"builtin"
function Platform.defaultMode(platform)
    if platform == "android" or platform == "windows" or platform == "macos"
            or platform == "linux" then
        return "system"
    end
    return "builtin"
end

--- 平台对应的输入后端模块名；没有系统输入法的平台返回 nil。
---@param platform string|nil
---@return string|nil
function Platform.backend(platform)
    if platform == "android" then
        return "features.system_ime"
    end
    if platform == "windows" or platform == "macos" or platform == "linux"
            or platform == "wsl" then
        return "features.system_text"
    end
    return nil
end

--- 读真实 Device；离线测试 / 无 device 模块时返回 nil。
---@return table|nil
function Platform.currentDevice()
    local ok, device = pcall(require, "device")
    if ok and type(device) == "table" then
        return device
    end
    return nil
end

---@return string
function Platform.current()
    return Platform.detect(Platform.currentDevice(), os)
end

---@return boolean
function Platform.isEinkCurrent()
    return Platform.isEink(Platform.currentDevice())
end

return Platform
