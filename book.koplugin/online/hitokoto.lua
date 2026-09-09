--[[--
一言。成功写入设置；失败或离线读设置。

@module koplugin.book.online.hitokoto
--]]

require("l10n").apply()
local MoonSettings = require("utils.settings")
local Online = require("online.base")
local _ = require("gettext")

local FALLBACKS = {
    { text = "读书不觉已春深，一寸光阴一寸金。", source = "王贞白" },
    { text = "纸上得来终觉浅，绝知此事要躬行。", source = "陆游" },
    { text = "旧书不厌百回读，熟读深思子自知。", source = "苏轼" },
    { text = "问渠那得清如许，为有源头活水来。", source = "朱熹" },
    { text = "读书破万卷，下笔如有神。", source = "杜甫" },
    { text = "黑发不知勤学早，白首方悔读书迟。", source = "颜真卿" },
    { text = "书山有路勤为径，学海无涯苦作舟。", source = "韩愈" },
    { text = "学而不思则罔，思而不学则殆。", source = "论语" },
    { text = "少壮不努力，老大徒伤悲。", source = "汉乐府" },
    { text = "腹有诗书气自华。", source = "苏轼" },
}

---@class BookOnlineHitokoto : BookOnline
local Hitokoto = setmetatable({
    ttl = 5 * 60,
}, Online)
Hitokoto.__index = Hitokoto

---@param payload table|nil
---@return string|nil
local function attribution(payload)
    if type(payload) ~= "table" then return nil end
    local who = Online.nonempty(payload.from_who)
    local work = Online.nonempty(payload.from)
    if who and work then return who .. " · " .. work end
    return who or work
end

---@param _args table|nil
---@return string
function Hitokoto:url(_args)
    return self.host .. "/hitokoto"
end

---@param body string|nil
---@return table|nil
function Hitokoto:parse(body)
    local payload = Online.decode(body)
    if type(payload) == "table" then
        local text = Online.nonempty(payload.hitokoto)
            or Online.nonempty(payload.content)
            or Online.nonempty(payload.text)
        if text then
            return {
                text = text,
                source = attribution(payload) or _("一言"),
            }
        end
    end
    local raw = Online.nonempty(body)
    if raw and raw:sub(1, 1) ~= "{" then
        return { text = raw, source = _("一言") }
    end
    return nil
end

---@param data { text: string, source: string }
function Hitokoto:store(data)
    local settings = MoonSettings.get()
    settings.lock_screen_quote_cache = data.text
    settings.lock_screen_quote_source_cache = data.source
    MoonSettings.save()
end

--- 无缓存时按年积日取一句，当天不变，避免墨水屏闪来闪去。
---@return { text: string, source: string }
function Hitokoto.fallback()
    local n = #FALLBACKS
    local i = ((tonumber(os.date("%j")) or 1) - 1) % n + 1
    return FALLBACKS[i]
end

---@return { text: string, source: string }
function Hitokoto:load()
    local settings = MoonSettings.get()
    local text = settings.lock_screen_quote_cache
    if type(text) == "string" and text ~= "" then
        return {
            text = text,
            source = settings.lock_screen_quote_source_cache or _("一言"),
        }
    end
    return Hitokoto.fallback()
end

return Hitokoto
