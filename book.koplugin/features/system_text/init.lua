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

--- show 之后候选窗锚点的重试时间（首绘前 inputbox.dimen 往往还没算出来）。
local AREA_RETRY_DELAYS = { 0.05, 0.15 }

local ok_ui, ui_manager = pcall(require, "ui/uimanager")
local UIManager = ok_ui and ui_manager or nil

-- 本次会话是否已经提示过「不可用」；WSL 未就绪 / SDL 起不来都会回退。
local notified = false
-- 当前是否有活动的文本输入会话；reset 只复位活动会话。
local active = false
-- 每次 show / hide 递增，用于作废过期的锚点重试。
local area_session = 0

---@return string
local function platform()
    return Platform.current()
end

---@param text string
local function showToast(text)
    local ok, Toast = pcall(require, "ui.themes.widgets.toast")
    if not ok or type(Toast) ~= "table" then return end
    pcall(function()
        Toast:new{ text = text, timeout = 3 }:show()
    end)
end

--- 每次会话只提示一次，避免连续点输入框刷屏。
local function notifyUnavailable()
    if notified then return end
    notified = true
    showToast(_("系统输入法不可用，已切回内置键盘"))
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
    local device = Platform.currentDevice()
    if device and type(device.startTextInput) == "function" then
        device:startTextInput()
    end
end

local function stopTextInput()
    local device = Platform.currentDevice()
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

--- 等输入框完成首绘后重试锚点；收起 / 换会话后过期重试自动作废。
---@param inputbox table|nil
---@param session number
local function scheduleAreaRetries(inputbox, session)
    if type(UIManager) ~= "table" or type(UIManager.scheduleIn) ~= "function" then
        return
    end
    for _idx, delay in ipairs(AREA_RETRY_DELAYS) do
        UIManager:scheduleIn(delay, function()
            if not active or session ~= area_session then return end
            setTextInputArea(inputbox)
        end)
    end
end

--- 接管一次键盘显示：启动系统文本输入并给候选窗定位。
--- 平台不支持 / WSL 未就绪 / SDL 起不来时返回 false，由 features.ime 回退原生 VK。
---@param vk table|nil VirtualKeyboard 实例（读 vk.inputbox）
---@return boolean
function SystemText.show(vk)
    if not SystemText.available() then return false end
    if SystemText.status() == "not_ready" then
        active = false
        area_session = area_session + 1
        notifyUnavailable()
        return false
    end
    local ok = pcall(startTextInput)
    if not ok then
        active = false
        area_session = area_session + 1
        notifyUnavailable()
        return false
    end
    active = true
    area_session = area_session + 1
    local inputbox = vk and vk.inputbox
    pcall(setTextInputArea, inputbox)
    scheduleAreaRetries(inputbox, area_session)
    return true
end

--- 收起系统文本输入。
---@param _vk table|nil
function SystemText.hide(_vk)
    active = false
    area_session = area_session + 1
    pcall(stopTextInput)
end

--- 丢弃系统输入法未提交的组合串：只复位活动会话，不重新打开文本输入。
---@return boolean
function SystemText.reset()
    if SystemText.status() ~= "ready" then return false end
    if not active then return false end
    active = false
    area_session = area_session + 1
    pcall(stopTextInput)
    return true
end

--- 打开测试输入框，用户真的输入一段文字后记录 pass / fail。
---@param on_done fun(ok: boolean)|nil
---@return boolean 是否打开了测试
function SystemText.test(on_done)
    if not SystemText.available() then return false end
    -- 未就绪时打开测试框只会收到空文本，不能记成「通过」。
    if SystemText.status() ~= "ready" then
        local settings = Settings.get("features.system_ime")
        settings.test_result = "fail"
        Settings.save("features.system_ime", settings)
        showToast(_("系统输入法未就绪，请先按设置页指引配置后重试"))
        if type(on_done) == "function" then on_done(false) end
        return false
    end
    local Test = require("features.system_text.test")
    Test.run(function(ok)
        local settings = Settings.get("features.system_ime")
        settings.test_result = ok and "pass" or "fail"
        Settings.save("features.system_ime", settings)
        showToast(ok and _("测试通过：输入框收到了文字")
            or _("测试未通过：输入框没有收到文字，请检查系统输入法"))
        if type(on_done) == "function" then on_done(ok) end
    end)
    return true
end

return SystemText
