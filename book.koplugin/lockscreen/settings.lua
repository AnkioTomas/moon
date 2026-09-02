--[[--
锁屏设置：组合锁屏与 KOReader screensaver 接管。

@module koplugin.book.lockscreen.settings
--]]

local lfs = require("libs/libkoreader-lfs")
local MoonSettings = require("utils.settings")

local M = {}
local revision = 0

--- 当前生效的主体配置；位置和宽窄是否可改由它的能力位决定。
local function component()
    return require("lockscreen.compose").plan().component
end

--- 接管前的 screensaver_* 快照存放键（照 pinyin 的布局快照做法）。
local PREVIOUS_KEY = "book_lockscreen_previous_screensaver"
--- 被接管的 KOReader 设置键
local KEYS = { "screensaver_type", "screensaver_document_cover", "screensaver_show_message" }

--- 首次接管时记下用户原本的 screensaver 配置。
--- 已有快照就不动：接管期间的中间值不是用户的选择。
---@return nil
local function snapshot()
    if G_reader_settings:readSetting(PREVIOUS_KEY) ~= nil then
        return
    end
    local saved = {}
    for _, key in ipairs(KEYS) do
        local value = G_reader_settings:readSetting(key)
        saved[key] = { present = value ~= nil, value = value }
    end
    G_reader_settings:saveSetting(PREVIOUS_KEY, saved)
end

--- 将有效锁屏图片交给 KOReader 的 document_cover screensaver。
---@param path string|nil
---@return nil
function M.applyCover(path)
    -- 快照必须在任何写入之前：下面两条早退路径也会改 screensaver_show_message，
    -- 不先记就等于改了用户配置又没留还原的依据。
    snapshot()
    if type(path) ~= "string" or path == "" then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
end

--- 撤下插件对系统 screensaver 的接管，恢复接管前的配置。
---
--- 以前是无条件写 `screensaver_type="disable"`：用户原本设的封面/书签/随机图锁屏
--- 会被永久改成「关闭」，关掉本插件功能也回不来。
---@return nil
function M.clearCover()
    local saved = G_reader_settings:readSetting(PREVIOUS_KEY)
    if type(saved) == "table" then
        for _, key in ipairs(KEYS) do
            local entry = saved[key]
            if entry and entry.present then
                G_reader_settings:saveSetting(key, entry.value)
            else
                G_reader_settings:delSetting(key)
            end
        end
        G_reader_settings:delSetting(PREVIOUS_KEY)
        return
    end
    -- 没有快照说明本插件还没接管过（或历史版本已经改过、原值无从得知）：
    -- 什么都不写。这里曾无条件 disable，把用户自己设的锁屏方式也一起关掉。
end

--- 配置变更后撤下旧图；下一次生成成功前不接管用户的锁屏设置。
local function invalidate()
    revision = revision + 1
    MoonSettings.get().lock_screen_day = nil
    M.clearCover()
end

--- 写一项配置：先撤下旧图再落盘，避免旧图继续显示。
---@param key string
---@param value any
local function save(key, value)
    invalidate()
    MoonSettings.get()[key] = value
    MoonSettings.save()
end

--- 是否启用组合锁屏。
---@return boolean
function M.isCompose()
    return MoonSettings.get().lock_screen == "compose"
end

--- 配置版本号；生成任务用它判断结果是否已经过期。
---@return number
function M.revision()
    return revision
end

--- 账单周期，非法值回退到最近 7 天。
---@return string
function M.billPeriod()
    local Bill = require("lockscreen.components.bill")
    local period = MoonSettings.get().lock_screen_bill_period
    return Bill.validPeriod(period) and period or "7d"
end

--- 自定义留言，空则用公共默认句子。
---@return string
function M.customMessage()
    local Text = require("utils.text")
    local U = require("lockscreen.components.util")
    local message = MoonSettings.get().lock_screen_custom_message
    return type(message) == "string" and Text.trim(message) ~= "" and message or U.FALLBACK_MESSAGE
end

--- 切换锁屏模式；切到 compose 时顺手把非法的主体/背景/位置纠回默认值。
---@param mode string "compose" 以外一律视为交还 KOReader
function M.setMode(mode)
    local c = MoonSettings.get()
    if mode ~= "compose" then
        revision = revision + 1
        c.lock_screen = "ko"
        MoonSettings.save()
        M.clearCover()
        return
    end
    local Components = require("lockscreen.components.base")
    local Background = require("lockscreen.background")
    local Layout = require("lockscreen.layout")
    c.lock_screen = "compose"
    c.lock_screen_component = Components.find(c.lock_screen_component) and c.lock_screen_component or "current"
    c.lock_screen_background = Background.validMode(c.lock_screen_background) and c.lock_screen_background or "bing"
    c.lock_screen_position = Layout.validPosition(c.lock_screen_position) and c.lock_screen_position or "center-center"
    c.lock_screen_wide = c.lock_screen_wide ~= false
    invalidate()
    MoonSettings.save()
end

--- 切换主体；不支持窄屏的主体强制回到宽屏。
---@param id string 未注册的 ID 直接忽略
function M.setComponent(id)
    local Components = require("lockscreen.components.base")
    local selected = Components.find(id)
    if not selected then return end
    invalidate()
    local c = MoonSettings.get()
    c.lock_screen_component = id
    if selected.supports_narrow == false then c.lock_screen_wide = true end
    MoonSettings.save()
end

--- 切换背景；非法值忽略。
---@param mode string
function M.setBackgroundMode(mode)
    if require("lockscreen.background").validMode(mode) then save("lock_screen_background", mode) end
end

--- 设置主体位置；主体不支持定位或位置非法则忽略。
---@param position string
function M.setPosition(position)
    if component().supports_position ~= false and require("lockscreen.layout").validPosition(position) then
        save("lock_screen_position", position)
    end
end

--- 设置宽/窄面板；不支持窄屏的主体永远存宽屏。
---@param wide boolean
function M.setWide(wide)
    save("lock_screen_wide", component().supports_narrow == false or wide == true)
end

--- 设置账单周期；非法值忽略。
---@param period string
function M.setBillPeriod(period)
    if require("lockscreen.components.bill").validPeriod(period) then save("lock_screen_bill_period", period) end
end

--- 设置自定义留言；去空白后为空则清除，回到默认句子。
---@param message string
function M.setCustomMessage(message)
    if type(message) ~= "string" then return end
    message = require("utils.text").trim(message)
    save("lock_screen_custom_message", message ~= "" and message or nil)
end

return M
