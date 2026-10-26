--[[--
番茄段评（App commentapi）：本章各段评论数、某段的评论页、把段落定位到章节 HTML。

协议要点（与正文同一套设备签名，见 reading.lua）：
- 统计 ``idea/list`` 只能 GET 无 body；列表 ``comment/list`` 是 POST，body 里 comment_source=2、
  group_type=15，翻页游标是 body 里的字符串偏移（首屏空串）。
- 签名不合规时服务端回 200 空响应，signedAsync 已把空响应归为失败，不会当成「没有段评」。
- 章节正文段落形如 ``<p ...><blk p_idx="N">正文</blk></p>``，统计的键就是 blk 的 p_idx。

@module koplugin.book.source.fanqie.reviews
--]]

local Crypto = require("source.fanqie.reading.crypto")
local Device = require("source.fanqie.reading.device")
local Reading = require("source.fanqie.reading")
local Text = require("utils.text")

local Reviews = {}

local STATS_PATH = "/novel/commentapi/idea/list/%s/v1/"
local LIST_PATH = "/novel/commentapi/comment/list/%s/v1/"
local PAGE_SIZE = 20
-- 段评气泡跟在段末：只用段尾这么多个字定位（要唯一），气泡画在最后一行右侧。

---@class FanqieReviewHotspot
---@field range string 段落序号（blk p_idx）
---@field text string
---@field total integer 本段评论数

local function query(device, ts_ms)
    local q = Crypto.build_common_query(device, ts_ms)
    q.compliance_status = "0"
    return q
end

--- 先确保设备身份，再发一次签名请求。
---@return CancelHandle
local function call(settings, name, path, build_body, cb)
    local job
    job = Device.ensureAsync(settings, function(device, err)
        if not device then
            cb(nil, err)
            return
        end
        job = Reading.signedAsync(device, name, path, query, build_body, cb)
    end)
    return { cancel = function() if job then job.cancel() end end }
end

--- 本章有评论的段落。
---@param settings FanqieSettings
---@param item_id string
---@param cb fun(hotspots: FanqieReviewHotspot[]|nil, err: string|nil)
---@return CancelHandle
function Reviews.hotspotsAsync(settings, item_id, cb)
    return call(settings, "comment_stats", STATS_PATH:format(item_id), nil, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local raw = type(wire.data.data) == "table" and wire.data.data or {}
        local out = {}
        for key, info in pairs(raw) do
            local pid, total = tonumber(key), type(info) == "table" and tonumber(info.count) or 0
            if pid and total > 0 then
                out[#out + 1] = { range = tostring(pid), text = "", total = total }
            end
        end
        table.sort(out, function(a, b) return tonumber(a.range) < tonumber(b.range) end)
        cb(out)
    end)
end

--- 设备解不了 HEIC（用户上传图）：改成同一张图的 800 宽 webp 缩略图（该地址不带签名）。
--- 路径不是用户图的（表情等）原样返回。
---@param url string
---@return string
local function displayUrl(url)
    if not url:find("~tplv%-[%w%-]+jpeg%.heic") then return url end
    local head = url:gsub("%?.*$", ""):match("^https?://[^/]+(/[^~]+)~tplv")
    if head and (head:match("^/tos%-cn%-i%-[%w]+/[^/]+$") or head:match("^/img/novel%-static/[^/]+$")) then
        return "https://p3-novel.byteimg.com" .. head .. "~tplv-1yzifmftcy-expand:800:0:0.webp"
    end
    return url
end

--- 评论里的图：`image_data_list.image_data` 是图数组（兼容直接是数组 / 单个对象）。
---@param content table
---@return { url: string, width: integer, height: integer }[]
local function images(content)
    local list = content.image_data_list
    if type(list) ~= "table" then return {} end
    local raw = list.image_data or list
    if raw.web_url then raw = { raw } end
    local out = {}
    for _idx, img in ipairs(raw) do
        local url = img.web_url or img.dynamic_url or img.expand_web_url
        if type(url) == "string" and url ~= "" then
            out[#out + 1] = { url = displayUrl(url), width = tonumber(img.width) or 0, height = tonumber(img.height) or 0 }
        end
    end
    return out
end

---@param entry table commentapi 评论条目
---@return WechatReview
local function item(entry)
    local c = type(entry.comment) == "table" and entry.comment or entry
    local common = type(c.common) == "table" and c.common or {}
    local user = type(common.user_info) == "table" and common.user_info or {}
    local base = type(user.base_info) == "table" and user.base_info or user
    local content = type(common.content) == "table" and common.content or {}
    local stat = type(c.stat) == "table" and c.stat or {}
    local created = tonumber(common.create_timestamp or common.create_time) or 0
    return {
        id = tostring(c.comment_id or ""),
        author = tostring(base.user_name or common.user_name or ""),
        content = tostring(content.text or common.text or ""),
        likes = tonumber(stat.digg_count) or 0,
        images = images(content),
        time = created > 1e11 and math.floor(created / 1000) or created,
    }
end

--- 某段的一页评论；max_idx 即游标偏移（首页 0）。
---@param settings FanqieSettings
---@param book_id string
---@param item_id string
---@param para_index integer
---@param max_idx integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return CancelHandle
function Reviews.pageAsync(settings, book_id, item_id, para_index, max_idx, cb)
    local JSON = require("json")
    return call(settings, "comment_list", LIST_PATH:format(item_id), function()
        return JSON.encode({
            chapter_id = item_id,
            comment_source = 2,
            comment_type = 1,
            group_type = 15,
            count = PAGE_SIZE,
            sort = 0,
            cursor = max_idx > 0 and tostring(max_idx) or "",
            business_param = { book_id = book_id, item_version = "0", para_index = para_index },
        })
    end, function(wire, err)
        if not wire then
            cb(nil, err)
            return
        end
        local list = wire.data.data_list
        if type(list) ~= "table" then
            -- code 为 0 却没有 data_list：被限流 / 风控，不能当成「0 条」。
            cb(nil, "番茄段评响应缺少 data_list")
            return
        end
        local info = type(wire.data.common_list_info) == "table" and wire.data.common_list_info or {}
        local items = {}
        for _idx, entry in ipairs(list) do
            if type(entry) == "table" then items[#items + 1] = item(entry) end
        end
        local cursor = tonumber(info.cursor)
        cb({
            items = items,
            total = tonumber(info.total) or #items,
            max_idx = cursor or max_idx,
            more = info.has_more == true and cursor ~= nil and cursor > max_idx and #items > 0,
        })
    end)
end

--- 章节 HTML 里每段的纯文本，键为 blk p_idx。
---@param html string
---@return table<string, string>
local function paragraphs(html)
    local out = {}
    for seg in html:gmatch("<p%s[^>]*>.-</p>") do
        local pid = seg:match('<blk[^>]-p_idx="(%d+)"')
        if pid then out[pid] = Text.trim((Text.stripHtml(seg):gsub('\n', ''))) end
    end
    return out
end

--- 把有评论的段落定位到章节 HTML。
---@param hotspots FanqieReviewHotspot[]
---@param html string
---@return table[]
function Reviews.locate(hotspots, html)
    return require("book.review_locate").locate(paragraphs(html), hotspots, html)
end

return Reviews
