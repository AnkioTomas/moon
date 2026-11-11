--[[--
一言。一次拉取并缓存最多 20 条（cache/online/hitokoto.json）。
请求带上用户勾选的类型（全选时不加 c，兼容旧接口）；类型变了 URL 变，缓存失效。
TTL 只决定何时再联网；已缓存句子过期后仍可展示，直到新的一批写入。
current() 仍只给未过期缓存（供 ensure / fresh）；展示走 quotes()。

@module koplugin.book.online.hitokoto
--]]

require("l10n").apply()
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

local BATCH_SIZE = 20

---@class BookOnlineHitokoto : BookOnline
local Hitokoto = setmetatable({
    name = "hitokoto",
    title = "一言",
    ttl = 3600,
    batch_size = BATCH_SIZE,
}, Online)
Hitokoto.__index = Hitokoto

---@param payload table
---@return string|nil
local function attribution(payload)
    local who = Online.nonempty(payload.from_who)
    local work = Online.nonempty(payload.from)
    if who and work then return who .. " · " .. work end
    return who or work
end

--- 把接口条目或缓存条目收成 { text, source } 列表。兼容旧的单条缓存。
---@param data table|nil
---@return { text: string, source: string }[]
local function normalizeQuotes(data)
    if type(data) ~= "table" then return {} end
    local rows
    if type(data.items) == "table" then
        rows = data.items
    elseif type(data.text) == "string" and data.text ~= "" then
        rows = { data }
    elseif type(data[1]) == "table" then
        rows = data
    else
        return {}
    end
    local out, seen = {}, {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local text = type(row.text) == "string" and row.text or nil
            if (not text or text == "") and type(row.hitokoto) == "string" then
                text = row.hitokoto
            end
            if type(text) == "string" and text ~= "" and not seen[text] then
                seen[text] = true
                local source = row.source
                if type(source) ~= "string" or source == "" then
                    source = attribution(row) or _("一言")
                end
                out[#out + 1] = { text = text, source = source }
            end
        end
    end
    return out
end

--- 官方分类，顺序固定；设置里的标签走 gettext。
--- 文学 / 原创 / 哲学 已占用书源词典，这里用「文学类」等以免撞键。
Hitokoto.TYPES = {
    { id = "a", label = _("动画") },
    { id = "b", label = _("漫画") },
    { id = "c", label = _("游戏") },
    { id = "d", label = _("文学类") },
    { id = "e", label = _("原创类") },
    { id = "f", label = _("来自网络") },
    { id = "g", label = _("其他") },
    { id = "h", label = _("影视") },
    { id = "i", label = _("诗词") },
    { id = "j", label = _("网易云") },
    { id = "k", label = _("哲学类") },
    { id = "l", label = _("抖机灵") },
}

local TYPE_SET = {}
for _idx, typ in ipairs(Hitokoto.TYPES) do
    TYPE_SET[typ.id] = true
end

---@return string[]
function Hitokoto.allTypeIds()
    local ids = {}
    for i, typ in ipairs(Hitokoto.TYPES) do
        ids[i] = typ.id
    end
    return ids
end

--- 过滤非法项并保持官方顺序；有效项不足 1 个时返回全部类型。
---@param saved any
---@return string[]
function Hitokoto.normalizeTypes(saved)
    local seen = {}
    if type(saved) == "table" then
        for _idx, id in ipairs(saved) do
            if type(id) == "string" and TYPE_SET[id] then
                seen[id] = true
            end
        end
    end
    local out = {}
    for _idx, typ in ipairs(Hitokoto.TYPES) do
        if seen[typ.id] then out[#out + 1] = typ.id end
    end
    if #out == 0 then return Hitokoto.allTypeIds() end
    return out
end

--- 用户勾选的类型。缺省、空、脏数据都当成全部类型。
---@return string[]
function Hitokoto.selectedTypes()
    local home = require("utils.settings").get("desktop.pages.home")
    return Hitokoto.normalizeTypes(home.home_hitokoto_types)
end

---@return string
function Hitokoto:url()
    local types = Hitokoto.selectedTypes()
    local url = self.host .. "/hitokoto?count=" .. BATCH_SIZE
    if #types < #Hitokoto.TYPES then
        url = url .. "&c=" .. table.concat(types, ",")
    end
    return url
end

---@param body string|nil
---@return table|nil
function Hitokoto:parse(body)
    local payload = Online.decode(body)
    if type(payload) ~= "table" then return nil end
    local rows
    if type(payload.hitokoto) == "string" then
        rows = { payload }
    elseif type(payload[1]) == "table" then
        rows = payload
    else
        return nil
    end
    local items = normalizeQuotes(rows)
    if #items == 0 then return nil end
    return { items = items }
end

--- 已缓存的句子，过期也给；类型变了（缓存 key 对不上当前 URL）则当没有，避免继续抽旧分类。
---@return { text: string, source: string }[]
function Hitokoto:quotes()
    if not self.data then self:load() end
    if type(self._cache_key) == "string" and self._cache_key ~= self:url() then
        return {}
    end
    return normalizeQuotes(self.data)
end

--- 无缓存时按年积日取一句，当天不变，避免墨水屏闪来闪去。
---@return { text: string, source: string }
function Hitokoto.fallback()
    local n = #FALLBACKS
    local i = ((tonumber(os.date("%j")) or 1) - 1) % n + 1
    return FALLBACKS[i]
end

--- 锁屏用：有缓存就按年积日从里面固定取一句；没有再用当天回退句。
---@return { text: string, source: string }
function Hitokoto.stable()
    local items = Hitokoto:quotes()
    if #items == 0 then return Hitokoto.fallback() end
    local i = ((tonumber(os.date("%j")) or 1) - 1) % #items + 1
    return items[i]
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

--- 首页一言：有缓存只从缓存抽；没有才用内置回退句。resume 随机抽，避开上一句。
---@param avoid string|nil
---@return BookExcerptQuote
function Hitokoto.random(avoid)
    local seen, pool = {}, {}
    local function push(text, source)
        if type(text) ~= "string" or text == "" or seen[text] then return end
        seen[text] = true
        local author, title = splitSource(source)
        pool[#pool + 1] = { text = text, author = author, title = title }
    end
    local cached = Hitokoto:quotes()
    if #cached > 0 then
        for i = 1, #cached do
            push(cached[i].text, cached[i].source)
        end
    else
        for i = 1, #FALLBACKS do
            push(FALLBACKS[i].text, FALLBACKS[i].source)
        end
    end
    return choose(pool, avoid)
end

--- 用户设置的联网刷新间隔；缺省、非法值按 1 小时。0 表示不联网。
---@return number
function Hitokoto.configuredTtl()
    local saved = require("utils.settings").get("desktop.pages.home").home_hitokoto_ttl
    if saved == 0 then return 0 end
    if type(saved) == "number" and saved > 0 then return saved end
    return 3600
end

--- ttl==0 时不入队；有缓存用缓存，没有再用内置句子。
function Hitokoto:ensureConfigured()
    local ttl = Hitokoto.configuredTtl()
    if ttl == 0 then return end
    self.ttl = ttl
    self:ensure()
end

return Hitokoto
