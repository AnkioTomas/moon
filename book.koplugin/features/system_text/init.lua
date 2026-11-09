--[[--
桌面 / WSL 的系统文本输入后端（SDL3）。

system 模式不弹内置 VK：`show()` 启动 SDL 文本输入（`Device:startTextInput`），
文字由 `SDL_EVENT_TEXT_INPUT` 交给焦点 InputText；`hide()` 关闭。
`SDL_SetTextInputArea` 把系统候选窗锚到当前输入框：FFI 声明留在插件侧，
窗口 / 符号缺失时静默降级，不影响文本输入本身。

WSL 只有 WSL 内 fcitx5（XIM）就绪时才接管；`XMODIFIERS` 不指向 fcitx 时
`status()` 返回 `not_ready`，`show()` 返回 false，让 features.ime 回退内置键盘。

@module koplugin.book.features.system_text
--]]

local Platform = require("features.ime.platform")
local Settings = require("utils.settings")
local _ = require("gettext")
require("l10n").apply()

local SystemText = {}

local DESKTOP = {
    linux = true,
    windows = true,
    macos = true,
    wsl = true,
}

---@return table|nil
local function currentDevice()
    local ok, device = pcall(require, "device")
    if ok and type(device) == "table" then
        return device
    end
    return nil
end

---@return string
local function platform()
    return Platform.current()
end

--- 后端是否适用于当前平台 / 环境；WSL 未就绪仍算适用，由 show 拒绝接管。
---@return boolean
function SystemText.available()
    if not DESKTOP[platform()] then return false end
    if Platform.isEinkCurrent() then return false end
    return true
end

--- WSL 内是否配好了 fcitx5 / XIM；Windows 输入法在 WSLg 下不可用。
---@return boolean
local function fcitxReady()
    local modifiers = os.getenv("XMODIFIERS") or ""
    return modifiers:lower():find("fcitx", 1, true) ~= nil
end

---@return "ready"|"not_ready"|"unavailable"
function SystemText.status()
    if not SystemText.available() then return "unavailable" end
    if platform() == "wsl" and not fcitxReady() then return "not_ready" end
    return "ready"
end

local function startTextInput()
    local device = currentDevice()
    if device and type(device.startTextInput) == "function" then
        device:startTextInput()
    end
end

local function stopTextInput()
    local device = currentDevice()
    if device and type(device.stopTextInput) == "function" then
        device:stopTextInput()
    end
end

---@param inputbox table|nil
---@return number
local function caretOffset(inputbox)
    local charlist = inputbox and inputbox.charlist
    local charpos = inputbox and inputbox.charpos
    if type(charlist) ~= "table" or type(charpos) ~= "number" or charpos <= 1 then
        return 0
    end
    local last = math.min(charpos - 1, #charlist)
    return #table.concat(charlist, "", 1, last)
end

--- 把输入框屏幕矩形与 caret 字节偏移交给 SDL；任何一步缺失都只跳过锚点。
---@param inputbox table|nil
---@return boolean
local function setTextInputArea(inputbox)
    local dimen = inputbox and inputbox.dimen
    if type(dimen) ~= "table" or type(dimen.x) ~= "number"
            or type(dimen.y) ~= "number" or type(dimen.w) ~= "number"
            or type(dimen.h) ~= "number" then
        return false
    end
    local ok_sdl, sdl = pcall(require, "ffi/SDL3")
    if not ok_sdl or type(sdl) ~= "table" or sdl.screen == nil then
        return false
    end
    local ok_util, util = pcall(require, "ffi/util")
    if not ok_util or type(util.loadSDL3) ~= "function" then
        return false
    end
    local lib = util.loadSDL3()
    if lib == nil then
        return false
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or type(ffi.cdef) ~= "function" then
        return false
    end
    -- SDL_Rect / SDL_Window 已在 KOReader 的 ffi/SDL3_h.lua 声明；这里只补函数。
    -- 重复声明由 pcall 兜底（不同 KOReader 版本可能已自带）。
    pcall(ffi.cdef, [[
        bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor);
    ]])
    local ok_rect, rect = pcall(function()
        local r = ffi.new("SDL_Rect")
        r.x, r.y = math.floor(dimen.x), math.floor(dimen.y)
        r.w, r.h = math.floor(dimen.w), math.floor(dimen.h)
        return r
    end)
    if not ok_rect then
        return false
    end
    local ok_fn, fn = pcall(function() return lib.SDL_SetTextInputArea end)
    if not ok_fn or fn == nil then
        return false
    end
    return pcall(fn, sdl.screen, rect, caretOffset(inputbox))
end

--- 接管一次键盘显示：启动系统文本输入并给候选窗定位。
--- 平台不支持 / WSL 未就绪 / SDL 起不来时返回 false，由 features.ime 回退原生 VK。
---@param vk table|nil VirtualKeyboard 实例（读 vk.inputbox）
---@return boolean
function SystemText.show(vk)
    if not SystemText.available() then return false end
    if SystemText.status() == "not_ready" then return false end
    local ok = pcall(startTextInput)
    if not ok then return false end
    pcall(setTextInputArea, vk and vk.inputbox)
    return true
end

--- 收起系统文本输入。
---@param _vk table|nil
function SystemText.hide(_vk)
    pcall(stopTextInput)
end

--- 丢弃系统输入法未提交的组合串：停一次再开，让 IME 重置预编辑。
---@return boolean
function SystemText.reset()
    if SystemText.status() ~= "ready" then return false end
    pcall(stopTextInput)
    pcall(startTextInput)
    return true
end

--- 打开测试输入框，用户真的输入一段文字后记录 pass / fail。
---@param on_done fun(ok: boolean)|nil
---@return boolean 是否打开了测试
function SystemText.test(on_done)
    if not SystemText.available() then return false end
    local Test = require("features.system_text.test")
    Test.run(function(ok)
        local settings = Settings.get("features.system_ime")
        settings.test_result = ok and "pass" or "fail"
        Settings.save("features.system_ime", settings)
        pcall(function()
            require("ui.themes.widgets.toast"):new{
                text = ok and _("测试通过：输入框收到了文字")
                    or _("测试未通过：输入框没有收到文字，请检查系统输入法"),
                timeout = 3,
            }:show()
        end)
        if type(on_done) == "function" then on_done(ok) end
    end)
    return true
end

return SystemText
