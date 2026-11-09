--[[--
系统输入法后端（Android）。

`features.ime` 在 system 模式下把 `VirtualKeyboard.showKeyboard` 交给这里；
本模块只实现 ticket 07 的后端契约：

  available(), show(vk), hide(vk), status(), onCreate(plugin)

- `show` 无法接管时返回 `false`（不抛错、不回 nil），让路由器当场回退原生 VK。
- 上屏文字直写 `inputbox:addChars/delChar/setText`，不走 `vk:addChar/delChar`，
  避免被内置拼音候选栏拦截。
- 键盘高度文件 `0` 视为系统键盘已收起：清活动状态并调 `parent:onKeyboardClosed()`。
- decimal / 密码 / 只读字段即使被误调也不接管。
- dex 缺失 / sha256 不符 / `DexClassLoader` 失败：先收系统键盘，延迟 150–200ms
  再补一次内置键盘（路由器已同步显示时不重复），Toast 提示，`last_status=not_ready`，
  用户选择 `input_mode` 保持不变。
- 不包装 `VirtualKeyboard.init`，也不提供独立设置入口。

@module koplugin.book.features.system_ime
--]]

local Settings = require("utils.settings")
local Snapshot = require("features.system_ime.snapshot")
local UIManager = require("ui/uimanager")
require("l10n").apply()
local _ = require("gettext")

local M = {}

local OWNER = "features.system_ime"
local POLL_INTERVAL = 0.05
local FALLBACK_DELAY = 0.18

---@class SystemIMEState
local state = {
    plugin_path = nil,
    prepared = false,
    engine = nil,
    error = nil,
    -- 当前接管中的 VK
    active_vk = nil,
    kb_active = false,
    polling = false,
    reserved_height = nil,
    last_height = nil,
    last_text = nil,
    last_cursor = nil,
    -- 回退
    fallback_vk = nil,
    skip_backend = false,
    notified = false,
}

--- Android 模块只在 KOReader 的 Android 启动器里存在。
---@return table|nil
local function androidModule()
    local ok, android = pcall(require, "android")
    if not ok or type(android) ~= "table" then return nil end
    return android
end

local function warn(...)
    local ok, logger = pcall(require, "utils.log")
    if ok and type(logger) == "table" and type(logger.warn) == "function" then
        logger.warn(...)
    end
end

---@param value string
local function setStatus(value)
    local ok, settings = pcall(Settings.get, OWNER)
    if not ok or type(settings) ~= "table" then return end
    if settings.last_status == value then return end
    settings.last_status = value
    pcall(Settings.save, OWNER)
end

---@return string|nil
local function storedStatus()
    local ok, settings = pcall(Settings.get, OWNER)
    if ok and type(settings) == "table" then
        return settings.last_status
    end
    return nil
end

--- 系统模式仍应交给内置键盘的字段；路由器已分流，这里是后端侧兜底。
---@param inputbox table|nil
---@return boolean
local function usesBuiltinForField(inputbox)
    if type(inputbox) ~= "table" then return false end
    if inputbox.input_type == "number" then return true end
    if inputbox.text_type == "password" then return true end
    if inputbox.is_password_type == true then return true end
    if inputbox.readonly == true then return true end
    return false
end

--- 当前编辑器文本与 UTF-16 光标（Java 侧选区下标）。
---@param vk table|nil
---@return string text
---@return integer cursor
local function editorState(vk)
    local inputbox = vk and vk.inputbox
    if type(inputbox) ~= "table" or type(inputbox.getText) ~= "function" then
        return "", 0
    end
    local ok, text = pcall(inputbox.getText, inputbox)
    if not ok or type(text) ~= "string" then text = "" end
    local charpos = tonumber(inputbox.charpos) or 1
    if charpos < 1 then charpos = 1 end
    return text, Snapshot.utf16Length(text, charpos - 1)
end

--- 惰性校验 dex / 加载 JNI；失败只记一次，本次会话不再重试。
---@return table|nil
local function ensureEngine()
    if state.prepared then return state.engine end
    state.prepared = true

    local android = androidModule()
    if not android then
        state.error = "android runtime unavailable"
        return nil
    end

    local loaded, engine, err = pcall(function()
        return require("features.system_ime.engine").load(android, state.plugin_path)
    end)
    if not loaded then
        engine, err = nil, engine
    end
    if type(engine) == "table" then
        state.engine = engine
        setStatus("ready")
        return engine
    end

    state.engine = nil
    state.error = err or "system ime not ready"
    setStatus("not_ready")
    warn("system ime: not ready", state.error)
    return nil
end

local function schedulePoll()
    if state.polling then return end
    state.polling = true
    UIManager:scheduleIn(POLL_INTERVAL, M.poll)
end

local function notifyUnavailable()
    if state.notified then return end
    state.notified = true
    local ok, Toast = pcall(require, "ui.themes.widgets.toast")
    if not ok or type(Toast) ~= "table" then return end
    pcall(function()
        Toast:new{ text = _("系统输入法不可用，已切回内置键盘"), timeout = 3 }:show()
    end)
end

--- 清空一次接管的活动状态（不动设置里的用户选择）。
local function resetActive(vk)
    state.kb_active = false
    state.active_vk = nil
    state.polling = false
    state.last_height = nil
    state.last_text = nil
    state.last_cursor = nil
    if type(vk) == "table" then vk.visible = false end
end

--- 系统键盘已收起：清状态并通知对话框重新排版。
---@param vk table|nil
function M.collapse(vk)
    local engine = state.engine
    resetActive(vk)
    if engine then pcall(engine.clear) end
    local inputbox = vk and vk.inputbox
    local parent = inputbox and inputbox.parent
    if parent and type(parent.onKeyboardClosed) == "function" then
        pcall(parent.onKeyboardClosed, parent)
    end
end

--- 回退序列：先隐藏系统键盘，再在 150–200ms 后补一次内置键盘。
--- 路由器在 show 返回 false 时会同步显示内置 VK；延迟回调发现已可见就跳过，
--- 因此只在后端被直连调用时承担「延迟显示」。
---@param vk table|nil
---@param reason any
---@param show_builtin fun(vk: table|nil)|nil
function M.fallback(vk, reason, show_builtin)
    local engine = state.engine
    resetActive(vk)
    if engine then
        pcall(engine.clear)
        pcall(engine.hide)
    end
    setStatus("not_ready")
    notifyUnavailable()
    warn("system ime: falling back to built-in keyboard", tostring(reason))

    state.fallback_vk = vk
    UIManager:scheduleIn(FALLBACK_DELAY, function()
        if state.fallback_vk ~= vk then return end
        state.fallback_vk = nil
        if type(vk) ~= "table" or vk.visible == true then return end
        if show_builtin then
            pcall(show_builtin, vk)
            return
        end
        if type(vk.showKeyboard) ~= "function" then return end
        -- 路由已包着 showKeyboard：置标记让下一次进入后端时直接返回 false，
        -- 由路由器走原生 VK，避免递归回退。
        state.skip_backend = true
        local ok, err = pcall(function() vk:showKeyboard() end)
        state.skip_backend = false
        if not ok then warn("system ime: deferred builtin show failed", tostring(err)) end
    end)
end

--- 把一份快照动作直接写进 inputbox。
---@param vk table
---@param content string
local function applySnapshot(vk, content)
    local inputbox = vk.inputbox
    if type(inputbox) ~= "table" then return end
    for _idx, action in ipairs(Snapshot.parse(content)) do
        if action.type == "chars" and type(inputbox.addChars) == "function" then
            pcall(inputbox.addChars, inputbox, action.text)
        elseif action.type == "backspace" and type(inputbox.delChar) == "function" then
            pcall(inputbox.delChar, inputbox)
        elseif action.type == "state" and type(inputbox.setText) == "function" then
            pcall(function()
                local current = type(inputbox.getText) == "function"
                    and (inputbox:getText() or "") or nil
                if current ~= nil and action.text ~= current then
                    inputbox.is_text_edited = true
                end
                inputbox:setText(action.text, true)
                if type(inputbox.moveCursorToCharPos) == "function" then
                    inputbox:moveCursorToCharPos(Snapshot.charPosFromUtf16(action.text, action.sel_end))
                end
            end)
        end
    end
end

--- 轮询快照 / 键盘高度；由 UIManager 每 50ms 调一次。
function M.poll()
    state.polling = false
    if not state.kb_active then return end
    local vk, engine = state.active_vk, state.engine
    if type(vk) ~= "table" or type(engine) ~= "table" then
        resetActive(vk)
        return
    end

    local height = engine.read_height()
    if height == 0 then
        M.collapse(vk)
        return
    end
    if height and height > 0 and height ~= state.last_height then
        state.last_height = height
        state.reserved_height = height
        if type(vk.dimen) == "table" then vk.dimen.h = height end
        local parent = vk.inputbox and vk.inputbox.parent
        if parent and type(parent.onKeyboardHeightChanged) == "function" then
            pcall(parent.onKeyboardHeightChanged, parent)
        end
    end

    local content = engine.take_input()
    if type(content) == "string" and content ~= "" then
        applySnapshot(vk, content)
    end

    local text, cursor = editorState(vk)
    if text ~= state.last_text or cursor ~= state.last_cursor then
        state.last_text, state.last_cursor = text, cursor
        pcall(engine.sync, text, cursor, cursor)
    end

    if state.kb_active then schedulePoll() end
end

--- 当前平台 / 环境是否可能有系统输入法。
---@return boolean
function M.available()
    return androidModule() ~= nil
end

--- 供设置页展示的后端状态。
---@return "ready"|"not_ready"|"unavailable"
function M.status()
    if not M.available() then return "unavailable" end
    local engine = ensureEngine()
    if storedStatus() == "not_ready" then return "not_ready" end
    if engine then return "ready" end
    return "not_ready"
end

--- 接管一次键盘显示；无法接管返回 false，由路由器回退原生 VK。
---@param vk table|nil
---@return boolean
function M.show(vk)
    if state.skip_backend then
        state.skip_backend = false
        return false
    end
    if not M.available() or type(vk) ~= "table" then return false end
    if usesBuiltinForField(vk.inputbox) then return false end

    local engine = ensureEngine()
    if not engine then
        M.fallback(vk, state.error or "not ready")
        return false
    end

    local text, cursor = editorState(vk)
    if state.kb_active and state.active_vk == vk then
        state.last_text, state.last_cursor = text, cursor
        vk.visible = true
        pcall(engine.sync, text, cursor, cursor)
        return true
    end

    if state.active_vk and state.active_vk ~= vk then
        if type(state.active_vk) == "table" then state.active_vk.visible = false end
        pcall(engine.clear)
        pcall(engine.hide)
    end

    state.active_vk = vk
    state.kb_active = true
    state.fallback_vk = nil
    state.last_height = nil
    state.last_text, state.last_cursor = text, cursor
    vk.visible = true
    if type(vk.dimen) == "table" and state.reserved_height then
        vk.dimen.h = state.reserved_height
    end

    pcall(engine.clear)
    local ok, err = pcall(engine.show, text, cursor, cursor)
    if not ok then
        M.fallback(vk, err)
        return false
    end
    setStatus("ready")
    schedulePoll()
    return true
end

--- 收起系统键盘并清空活动状态。
---@param vk table|nil
function M.hide(vk)
    local engine = state.engine
    resetActive(vk)
    state.fallback_vk = nil
    if engine then
        pcall(engine.clear)
        pcall(engine.hide)
    end
end

--- 插件启动：记录插件路径并尝试准备 dex；非 Android 是空操作。
---@param plugin table|nil
function M.onCreate(plugin)
    local path = plugin and plugin.path
    if type(path) == "string" and path ~= "" then
        state.plugin_path = path
    end
    if not M.available() then return end
    ensureEngine()
end

return M
