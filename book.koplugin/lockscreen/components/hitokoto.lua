--[[--
主体：一言。

@module koplugin.book.lockscreen.components.hitokoto
--]]

local Request = require("http.request")
local MoonSettings = require("utils.settings")
local JSON = require("json")
local QuotePanel = require("lockscreen.components.quote_panel")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "hitokoto",
    label = _("一言"),
    needs_network = true,
    refresh_on_resume = true,
    layout = "quote",
}

-- 将接口返回的作者和作品拼成简短出处。
--- 字段缺失时逐级回退到已有的作者或作品字段。
---@param payload table|nil
---@return string|nil
local function attribution(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local who = type(payload.from_who) == "string" and payload.from_who ~= "" and payload.from_who or nil
    local work = type(payload.from) == "string" and payload.from ~= "" and payload.from or nil
    if who and work then
        return who .. " · " .. work
    end
    return who or work
end

--- 由公共语句面板负责排版，本组件只转发文本和出处。
---@param position string
---@param wide boolean
---@param text string
---@param source string
---@return table[]
function M.blocks(position, wide, text, source)
    return QuotePanel.blocks(text, source, position, wide)
end

--- 异步拉取一言文案；失败回落缓存。
--- 网络请求只更新文本缓存，不直接触碰锁屏文件。
---@param cb fun(text: string, source: string)
---@return table|nil
function M.ensureText(cb)
    local c = MoonSettings.get()
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        cb(c.lock_screen_quote_cache or U.FALLBACK_MESSAGE, c.lock_screen_quote_source_cache or _("一言"))
        return nil
    end
    return Request.get("https://api.ankio.net/hitokoto", { timeout = 20 }, function(body)
        local fetched
        local fetched_source
        if body then
            local ok, data = pcall(JSON.decode, body)
            if ok and type(data) == "table" then
                local payload = type(data.data) == "table" and data.data or data
                fetched = payload.hitokoto or payload.content or payload.text
                fetched_source = attribution(payload)
            elseif body:match("%S") then
                fetched = body
            end
        end
        if type(fetched) == "string" and fetched ~= "" then
            c.lock_screen_quote_cache = fetched
            c.lock_screen_quote_source_cache = fetched_source or _("一言")
            MoonSettings.save()
            cb(fetched, fetched_source or _("一言"))
        else
            cb(c.lock_screen_quote_cache or U.FALLBACK_MESSAGE, c.lock_screen_quote_source_cache or _("一言"))
        end
    end)
end

return M
