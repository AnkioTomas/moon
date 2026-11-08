--[[--
快看漫画响应到书籍、目录和页图。

目录不在 JSON 里。话题页把章节嵌进 `window.__NUXT__`，由 page.lua 拆开后再交给这里。
未解锁章节 `locked == true`，不给页图。

@module source.kuaikan.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

Mapper.TOC_VERSION = 1
local SOURCE_ID = "kuaikan"

---@param topic_id string
---@param comic_id string
---@param pos ProgressPosition
---@param fraction number 章内比例
---@param count integer 图片页数
---@param now integer 毫秒时间
---@return table|nil
function Mapper.progressReport(topic_id, comic_id, pos, fraction, count, now)
    local topic, comic = tonumber(topic_id), tonumber(comic_id)
    if not topic or not comic or topic <= 0 or comic <= 0 or topic % 1 ~= 0 or comic % 1 ~= 0 then return nil end
    local read_count = math.max(1, math.min(count, pos.page or math.ceil(fraction * count)))
    return {
        topic_id = topic, comic_id = comic, total_count = count,
        read_count = read_count, max_read_count = read_count,
        read_time = now, max_read_count_time = now,
    }
end

---@param value any
---@return string
local function clean(value)
    if type(value) ~= "string" then return "" end
    return Text.trim(value)
end

---@param row table
---@return string
local function author(row)
    if type(row.author_name) == "string" then return clean(row.author_name) end
    local user = row.user
    if type(user) == "table" then return clean(user.nickname) end
    return ""
end

---@param row table
---@return string|nil
local function cover(row)
    local url = row.vertical_image_url or row.cover_image_url
    if type(url) ~= "string" or url == "" then return nil end
    return url
end

---@param row table
---@return Book|nil
local function book(row)
    if type(row) ~= "table" or row.id == nil or clean(row.title) == "" then return nil end
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(row.id),
        title = clean(row.title),
        authors = author(row),
        cover = cover(row),
        intro = clean(row.description),
    }
end

---@param rows table|nil
---@return Book[]
local function books(rows)
    local out = {}
    if type(rows) ~= "table" then return out end
    for _idx, row in ipairs(rows) do
        local item = book(row)
        if item then out[#out + 1] = item end
    end
    return out
end

---@param node string|nil
---@return string
function Mapper.storeNode(node)
    if type(node) ~= "string" or not node:match("^%d+:%d+:%d+:%d+:%d+$") then return "0:1:0:0:1" end
    -- 各筛选维度的枚举与官网 /tag/ 链接一致。
    local parts = {}
    for value in node:gmatch("%d+") do parts[#parts + 1] = value end
    if tonumber(parts[2]) < 1 or tonumber(parts[2]) > 4
        or tonumber(parts[3]) > 3 or tonumber(parts[4]) > 2
        or tonumber(parts[5]) < 1 or tonumber(parts[5]) > 3 then return "0:1:0:0:1" end
    return node
end

---@param wire table|nil
---@param node string
---@param page integer
---@return Book[]|nil, StoreChipGroup[]|nil, boolean|nil
function Mapper.store(wire, node, page)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 or type(wire.hits) ~= "table" then return nil end
    local rows, tags, total = wire.hits.topicMessageList, wire.hits.topicCategories, tonumber(wire.total)
    if type(rows) ~= "table" or type(tags) ~= "table" or not total or total < 0 then return nil end
    local _ = require("l10n").get("source.kuaikan")
    local parts = {}
    for value in Mapper.storeNode(node):gmatch("%d+") do parts[#parts + 1] = value end
    local categories = {}
    for _idx, tag in ipairs(tags) do
        local id = type(tag) == "table" and (tag.tag_id or tag.tagId)
        if id == nil or not tostring(id):match("^%d+$") or clean(tag.title) == "" then return nil end
        categories[#categories + 1] = { tostring(id), tag.title }
    end
    local dimensions = {
        { _("分类"), categories },
        { _("地区"), { { "1", _("全部") }, { "2", _("国漫") }, { "3", _("韩漫") }, { "4", _("日漫") } } },
        { _("价格"), { { "0", _("全部") }, { "1", _("免费") }, { "2", _("付费") }, { "3", _("VIP抢先看") } } },
        { _("状态"), { { "0", _("全部") }, { "1", _("连载中") }, { "2", _("已完结") } } },
        { _("排序"), { { "1", _("推荐") }, { "2", _("最火热") }, { "3", _("新上架") } } },
    }
    local groups = {}
    for index, dimension in ipairs(dimensions) do
        local chips = {}
        local saved = parts[index]
        for _idx, choice in ipairs(dimension[2]) do
            parts[index] = choice[1]
            chips[#chips + 1] = { id = table.concat(parts, ":"), title = choice[2] }
        end
        parts[index] = saved
        local group = require("source.browse").group(chips, table.concat(parts, ":"))
        group.title = dimension[1]
        groups[#groups + 1] = group
    end
    local list = books(rows)
    if #list ~= #rows then return nil end
    return list, groups, page * 48 < total
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.search(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local topics = type(wire.data) == "table" and wire.data.topics or nil
    local hit = type(topics) == "table" and topics.hit or nil
    if type(hit) ~= "table" then return nil end
    return books(hit)
end

---@param wire table|nil
---@return Book[]|nil
function Mapper.home(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local rows = type(wire.data) == "table" and wire.data.popularity_topics or nil
    if type(rows) ~= "table" then return nil end
    return books(rows)
end

--- 收藏列表。`data.topics` 是书卡数组，空数组是空收藏。
---@param wire table|nil
---@return Book[]|nil, integer|nil
function Mapper.fav(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local data = type(wire.data) == "table" and wire.data or nil
    local rows = data and data.topics or nil
    local total = data and tonumber(data.total)
    if type(rows) ~= "table" or not total or total < 0 or total ~= math.floor(total) then return nil end
    local list = books(rows)
    if #list ~= #rows then return nil end
    return list, total
end

--- 话题页拆出来的章节行。
---@param rows table[]|nil
---@return BookChapter[]|nil
function Mapper.chapters(rows)
    if type(rows) ~= "table" then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) == "table" and row.id ~= nil and clean(row.title) ~= "" then
            out[#out + 1] = {
                idx = #out + 1,
                uid = tostring(row.id),
                title = clean(row.title),
                vip = row.locked == true,
            }
        end
    end
    if not out[1] then return nil end
    out[1].toc_version = Mapper.TOC_VERSION
    return out
end

--- 详情。作者是页面脚本里单独赋的昵称。
---@param info table|nil
---@param nickname string|nil
---@return Book|nil
function Mapper.detail(info, nickname)
    local item = book(info or {})
    if item and type(nickname) == "string" and nickname ~= "" then item.authors = nickname end
    return item
end

--- 话题评论。网页只展示 `replied_comment_id` 为 0 的楼，字段是 user.nickname、content、created_at_info、likes_count。
--- 第二返回值是 data.total。
---@param wire table|nil
---@return { id: string|nil, author: string, text: string, time: string|nil, likes: number|nil }[]|nil
---@return integer|nil
function Mapper.comments(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 or type(wire.data) ~= "table" then
        return nil
    end
    local rows = wire.data.comments
    local total = tonumber(wire.data.total)
    if type(rows) ~= "table" or not total or total < 0 then return nil end
    local out = {}
    for _idx, row in ipairs(rows) do
        if type(row) ~= "table" or type(row.content) ~= "string" or tonumber(row.replied_comment_id) == nil then
            return nil
        end
        if tonumber(row.replied_comment_id) == 0 then
            local user = type(row.user) == "table" and row.user or {}
            local stamp = type(row.created_at_info) == "string" and row.created_at_info:match("^(%S+)") or nil
            out[#out + 1] = {
                id = (type(row.id) == "string" or type(row.id) == "number") and tostring(row.id) or nil,
                author = type(user.nickname) == "string" and user.nickname or "",
                text = row.content,
                time = stamp,
                likes = tonumber(row.likes_count),
            }
        end
    end
    return out, total
end

--- 一话的页图 URL。locked 的章节没有图。
---@param wire table|nil
---@return string[]|nil
---@return string|nil
function Mapper.images(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil end
    local info = type(wire.data) == "table" and wire.data.comic_info or nil
    if type(info) ~= "table" then return nil end
    if info.locked == true then return nil, "locked" end
    local rows = info.comic_images
    if type(rows) ~= "table" then return nil end
    local urls = {}
    for _idx, row in ipairs(rows) do
        local url = type(row) == "table"
            and (type(row.url1280) == "string" and row.url1280 ~= "" and row.url1280 or row.url) or nil
        if type(url) ~= "string" or url == "" then return nil end
        urls[#urls + 1] = url
    end
    if #urls == 0 then return nil end
    return urls
end

---@param wire table|nil
---@return { user_id: string }|nil
---@return string|nil
function Mapper.account(wire)
    if type(wire) ~= "table" or tonumber(wire.code) ~= 200 then return nil, "invalid" end
    if type(wire.data) ~= "table" or type(wire.data.user_info) ~= "table" then return nil, "invalid" end
    ---@type table<string, any>
    local user = wire.data.user_info
    local authenticated = tonumber(user.authenticate)
    if authenticated == 0 then return nil, "unauthorized" end
    if not authenticated or authenticated < 0 then return nil, "invalid" end
    local id = user.user_id
    if type(id) ~= "number" and type(id) ~= "string" then return nil, "invalid" end
    id = tostring(id)
    if not id:match("^%d+$") then return nil, "invalid" end
    id = id:gsub("^0+", "")
    if id == "" then return nil, "invalid" end
    return { user_id = id }
end

Mapper.WECHAT_CALLBACK = "https://www.kuaikanmanhua.com/v1/passport/login/pc/user_wechat_login_check"

---@param country string
---@param number string
---@return string|nil
function Mapper.phone(country, number)
    country, number = Text.trim(country), Text.trim(number)
    if not country:match("^%+%d+$") or #country > 5 then return nil end
    if country == "+86" then
        if not number:match("^1[3-9]%d%d%d%d%d%d%d%d%d$") then return nil end
    elseif not number:match("^%d+$") or #number < 7 or #number > 12 then
        return nil
    end
    return country .. "-" .. number
end

---@param phone string
---@param password string
---@param captcha { ticket: string, random: string }
---@return table
function Mapper.passwordFields(phone, password, captcha)
    local AES = require("crypto.aes")
    -- 官网公开脚本的 UTF-8 原始密钥、IV 与 PKCS7，不是 Base64 密钥或口令派生。
    local key, iv = "CRL66bnFXBaLt39tgU8GJrVymV/jBJqv", "vdjsaj42mxfkck39"
    return {
        phone = Text.base64Encode(AES.cbc_encrypt(phone, key, iv)),
        password = Text.base64Encode(AES.cbc_encrypt(password, key, iv)),
        remember = 1, ticket = captcha.ticket, random = captcha.random, verify_provider = "tencent",
    }
end

---@param location string|nil
---@return { url: string, state: string }|nil
function Mapper.qrLocation(location)
    if type(location) ~= "string" or not location:match("^https://open%.weixin%.qq%.com/connect/qrconnect%?") then return nil end
    local params = {}
    for key, value in location:match("%?([^#]*)"):gmatch("([^&=]+)=([^&]*)") do
        key = Text.urlDecode(key)
        if params[key] then return nil end
        params[key] = Text.urlDecode(value)
    end
    if params.appid ~= "wx92ba65b18ed55877" or params.scope ~= "snsapi_login"
        or params.response_type ~= "code" or params.redirect_uri ~= Mapper.WECHAT_CALLBACK
        or not params.state or params.state == "" then return nil end
    return { url = location, state = params.state }
end

---@param raw string
---@return integer|nil
---@return string|nil
function Mapper.qrStatus(raw)
    local ok, wire = pcall(require("json").decode, raw)
    local status, code
    if ok and type(wire) == "table" then
        status, code = tonumber(wire.wx_errcode), wire.wx_code
    else
        status = tonumber(raw:match("wx_errcode%s*=%s*(%d+)"))
        code = raw:match("wx_code%s*=%s*['\"]([^'\"]*)['\"]")
    end
    if not status or (status == 405 and (type(code) ~= "string" or code == "")) then return nil end
    return status, code
end

return Mapper
