--[[--
锁屏设置：组合锁屏与 KOReader screensaver 接管。

@module koplugin.book.features.lockscreen.settings
--]]

local lfs = require("libs/libkoreader-lfs")
local MoonSettings = require("utils.settings")

local M = {}
local revision = 0

--- 广告版 Kindle：KOReader 接管不了锁屏。去广告脚本会删掉这两处广告缓存，还在就是没去。
local AD_PATHS = { "/var/local/adunits", "/mnt/us/.assets" }

---@return boolean
function M.hasAds()
    if not require("device"):isKindle() then return false end
    for _idx, path in ipairs(AD_PATHS) do
        if lfs.attributes(path, "mode") then return true end
    end
    return false
end

--- 与 scriptlets 的 Disable ADs 同一套动作：删广告缓存、关掉系统的广告开关。
--- 命令全是固定串，没有用户输入。
---@return boolean ok
function M.removeAds()
    for _idx, path in ipairs(AD_PATHS) do
        os.execute("rm -rf " .. path)
    end
    local code = os.execute([[sqlite3 /var/local/appreg.db 'update properties set value = "false" where name = "adunit.viewable";']])
    return (code == 0 or code == true) and not M.hasAds()
end

--- 当前生效的主体配置；位置和宽窄是否可改由它的能力位决定。
local function component()
    return require("features.lockscreen.compose").component()
end

--- 接管前的 screensaver_* 快照存放键（照 pinyin 的布局快照做法）。
local PREVIOUS_KEY = "book_lockscreen_previous_screensaver"
--- 被接管的 KOReader 设置键
local KEYS = { "screensaver_type", "screensaver_document_cover", "screensaver_show_message",
    "screensaver_img_background", "screensaver_stretch_images" }

--- 首次接管时记下用户原本的 screensaver 配置。
--- 已记的键不动：接管期间的中间值不是用户的选择；旧版快照缺的新键在首次写入前补记。
local function snapshot()
    local saved = G_reader_settings:readSetting(PREVIOUS_KEY) or {}
    ---@cast saved table
    local changed = false
    for _idx, key in ipairs(KEYS) do
        if saved[key] == nil then
            local value = G_reader_settings:readSetting(key)
            saved[key] = { present = value ~= nil, value = value }
            changed = true
        end
    end
    if changed then G_reader_settings:saveSetting(PREVIOUS_KEY, saved) end
end

--- 把一项接管键还原成快照里的用户值。
---@param saved table
---@param key string
local function restore(saved, key)
    local entry = saved[key]
    if entry and entry.present then
        G_reader_settings:saveSetting(key, entry.value)
    else
        G_reader_settings:delSetting(key)
    end
end

--- 将有效锁屏图片交给 KOReader 的 document_cover screensaver。
--- 透明图：KOReader 不铺底色也不拉伸，透明处露出当前页；否则这两项保持用户自己的值。
---@param path string|nil
---@param transparent boolean|nil
function M.applyCover(path, transparent)
    -- 快照必须在任何写入之前：下面两条早退路径也会改 screensaver_show_message，
    -- 不先记就等于改了用户配置又没留还原的依据。
    snapshot()
    local attr = type(path) == "string" and path ~= "" and lfs.attributes(path)
    if not attr or attr.mode ~= "file" or (attr.size or 0) == 0 then
        G_reader_settings:saveSetting("screensaver_show_message", true)
        return
    end
    G_reader_settings:saveSetting("screensaver_type", "document_cover")
    G_reader_settings:saveSetting("screensaver_document_cover", path)
    G_reader_settings:saveSetting("screensaver_show_message", false)
    if transparent then
        G_reader_settings:saveSetting("screensaver_img_background", "none")
        G_reader_settings:saveSetting("screensaver_stretch_images", false)
    else
        local saved = G_reader_settings:readSetting(PREVIOUS_KEY)
        ---@cast saved table
        restore(saved, "screensaver_img_background")
        restore(saved, "screensaver_stretch_images")
    end
end

--- 撤下插件对系统 screensaver 的接管，恢复接管前的配置。
---
--- 以前是无条件写 `screensaver_type="disable"`：用户原本设的封面/书签/随机图锁屏
--- 会被永久改成「关闭」，关掉本插件功能也回不来。
function M.clearCover()
    local saved = G_reader_settings:readSetting(PREVIOUS_KEY) --[[@as table<string, { present: boolean, value: any }>|nil]]
    if type(saved) == "table" then
        for _idx, key in ipairs(KEYS) do restore(saved, key) end
        G_reader_settings:delSetting(PREVIOUS_KEY)
    end
    -- 没有快照说明本插件还没接管过（或历史版本已经改过、原值无从得知）：
    -- 什么都不写。这里曾无条件 disable，把用户自己设的锁屏方式也一起关掉。
end

--- 配置变更后撤下旧图；下一次生成成功前不接管用户的锁屏设置。
local function invalidate()
    revision = revision + 1
    MoonSettings.get("features.lockscreen").lock_screen_day = nil
    M.clearCover()
end

--- 写一项配置：先撤下旧图再落盘，避免旧图继续显示。
---@param key string
local function save(key, value)
    invalidate()
    MoonSettings.get("features.lockscreen")[key] = value
    MoonSettings.save("features.lockscreen")
end

--- 是否启用组合锁屏。
---@return boolean
function M.isCompose()
    return MoonSettings.get("features.lockscreen").lock_screen == "compose"
end

--- 配置版本号；生成任务用它判断结果是否已经过期。
---@return number
function M.revision()
    return revision
end

--- 账单周期，非法值回退到最近 7 天。
---@return string
function M.billPeriod()
    local Bill = require("features.lockscreen.components.bill")
    local period = MoonSettings.get("features.lockscreen").lock_screen_bill_period
    return Bill.validPeriod(period) and period or "7d"
end

--- 自定义留言，空则用公共默认句子。
---@return string
function M.customMessage()
    local Text = require("utils.text")
    local U = require("features.lockscreen.components.util")
    local message = MoonSettings.get("features.lockscreen").lock_screen_custom_message
    return type(message) == "string" and Text.trim(message) ~= "" and message or U.FALLBACK_MESSAGE
end

-- 背景与主体拆开前，这些主体自带背景（无视用户选的背景）：搬成等价的「背景, 主体」。
local SPLIT = {
    myrl = { "myrl", "none" },
    poster = { "poster", "none" },
    cover_card = { "cover", "capsule" },
    minimal = { "none", "minimal" },
}

--- 一次性迁移旧主体设置；lock_screen_split 标记已迁移，之后用户给极简另选背景不再被改回。
function M.migrate()
    local c = MoonSettings.get("features.lockscreen")
    if c.lock_screen_split then return end
    local pair = SPLIT[c.lock_screen_component]
    if pair then c.lock_screen_background, c.lock_screen_component = pair[1], pair[2] end
    c.lock_screen_split = true
    MoonSettings.save("features.lockscreen")
end

--- 切换锁屏模式；切到 compose 时顺手把非法的主体/背景/位置纠回默认值。
---@param mode string "compose" 以外一律视为交还 KOReader
function M.setMode(mode)
    local c = MoonSettings.get("features.lockscreen")
    if mode ~= "compose" then
        revision = revision + 1
        c.lock_screen = "ko"
        MoonSettings.save("features.lockscreen")
        M.clearCover()
        return
    end
    local Components = require("features.lockscreen.components.base")
    local Background = require("features.lockscreen.background")
    local Layout = require("features.lockscreen.layout")
    c.lock_screen = "compose"
    c.lock_screen_component = Components.find(c.lock_screen_component) and c.lock_screen_component or "current"
    c.lock_screen_background = Background.validMode(c.lock_screen_background) and c.lock_screen_background or "bing"
    c.lock_screen_position = Layout.validPosition(c.lock_screen_position) and c.lock_screen_position or "center-center"
    c.lock_screen_wide = c.lock_screen_wide ~= false
    invalidate()
    MoonSettings.save("features.lockscreen")
end

--- 切换主体；组件自身的固定形态由 compose 解析，不污染共享形态偏好。
---@param id string 未注册的 ID 直接忽略
function M.setComponent(id)
    local Components = require("features.lockscreen.components.base")
    if Components.find(id) then save("lock_screen_component", id) end
end

--- 切换背景；非法值忽略。
---@param mode string
function M.setBackgroundMode(mode)
    if require("features.lockscreen.background").validMode(mode) then save("lock_screen_background", mode) end
end

--- 设置主体位置；主体不支持定位或位置非法则忽略。
---@param position string
function M.setPosition(position)
    if component().supports_position ~= false and require("features.lockscreen.layout").validPosition(position) then
        save("lock_screen_position", position)
    end
end

--- 设置宽/窄面板；固定形态主体忽略该设置，保留其他主体的偏好。
---@param wide boolean
function M.setWide(wide)
    if component().supports_narrow ~= false then
        save("lock_screen_wide", wide == true)
    end
end

--- 设置账单周期；非法值忽略。
---@param period string
function M.setBillPeriod(period)
    if require("features.lockscreen.components.bill").validPeriod(period) then save("lock_screen_bill_period", period) end
end

--- 设置海报墙风格；非法值忽略。
---@param style string
function M.setPosterStyle(style)
    if require("features.lockscreen.poster").validStyle(style) then save("lock_screen_poster_style", style) end
end

--- 设置统计页面背景的页面；非法值忽略。
---@param page string
function M.setInsightPage(page)
    if require("features.lockscreen.insight").validPage(page) then save("lock_screen_insight_page", page) end
end

--- 设置文字海报版式。
---@param style string
function M.setTypoStyle(style)
    if require("features.lockscreen.typo").validStyle(style) then save("lock_screen_typo_style", style) end
end

--- 设置文字海报字体；空 id 表示自动（优先宋体）。
---@param id string 字体 id（字体文件名或微信读书字体 id）
---@param name string|nil 显示名
function M.setTypoFont(id, name)
    local c = MoonSettings.get("features.lockscreen")
    invalidate()
    c.lock_screen_typo_font = id ~= "" and id or nil
    c.lock_screen_typo_font_name = id ~= "" and name or nil
    MoonSettings.save("features.lockscreen")
end

--- 设置自定义背景图路径（路径选择器选出的真实文件）。
---@param path string
function M.setCustomImage(path)
    save("lock_screen_custom_image", path)
end

--- 设置壁纸文件夹路径（路径选择器选出的真实目录）。
---@param path string
function M.setFolder(path)
    save("lock_screen_folder", path)
end

--- 设置自定义留言；去空白后为空则清除，回到默认句子。
---@param message string
function M.setCustomMessage(message)
    if type(message) ~= "string" then return end
    message = require("utils.text").trim(message)
    save("lock_screen_custom_message", message ~= "" and message or nil)
end

return M
