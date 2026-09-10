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

--- 「作者 · 作品」拆成右侧两行；拆不开就整段当作者。
---@param source string|nil
---@return string
---@return string
local function splitSource(source)
    source = type(source) == "string" and source or ""
    local who, work = source:match("^(.-) · (.+)$")
    if who and work then return who, work end
    return source, ""
end

---@param pool { text: string, author: string, title: string }[]
---@param avoid string|nil
---@return { text: string, author: string, title: string }
local function choose(pool, avoid)
    if #pool == 0 then return { text = "", author = "", title = "" } end
    if #pool == 1 then return pool[1] end
    local i = math.random(#pool)
    if avoid and pool[i].text == avoid then
        i = i % #pool + 1
    end
    return pool[i]
end

--- 首页一言：回退句 + 缓存 + 当日日报，resume 随机抽，不跟日缓存绑死。
---@param daily { quote_text: string|nil, quote_from: string|nil }|nil
---@param avoid string|nil
---@return { text: string, author: string, title: string }
function Hitokoto.random(daily, avoid)
    local seen, pool = {}, {}
    local function push(text, source)
        if type(text) ~= "string" or text == "" or seen[text] then return end
        seen[text] = true
        local author, title = splitSource(source)
        pool[#pool + 1] = { text = text, author = author, title = title }
    end
    for i = 1, #FALLBACKS do
        push(FALLBACKS[i].text, FALLBACKS[i].source)
    end
    local settings = MoonSettings.get()
    push(settings.lock_screen_quote_cache, settings.lock_screen_quote_source_cache)
    if type(daily) == "table" then
        push(daily.quote_text, daily.quote_from)
    end
    return choose(pool, avoid)
end

return Hitokoto
