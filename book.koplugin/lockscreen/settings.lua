--[[--
锁屏设置：组合锁屏与 KOReader screensaver 接管。

@module koplugin.book.lockscreen.settings
--]]

local lfs = require("libs/libkoreader-lfs")

local M = {}

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
        -- nil 也要记：用 false 占位表示「原本没有这个键」
        local value = G_reader_settings:readSetting(key)
        saved[key] = value == nil and false or value
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
            local value = saved[key]
            if value == false then
                G_reader_settings:delSetting(key)
            else
                G_reader_settings:saveSetting(key, value)
            end
        end
        G_reader_settings:delSetting(PREVIOUS_KEY)
        return
    end
    -- 没有快照说明本插件还没接管过（或历史版本已经改过、原值无从得知）：
    -- 什么都不写。这里曾无条件 disable，把用户自己设的锁屏方式也一起关掉。
end

return M
