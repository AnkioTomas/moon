--[[--
晋江段评：本章各段评论数、某段的评论页、把段落定位到章节 HTML。

走晋江网页版的段评接口（www.jjwxc.net/app.jjwxc/Pc/comment/…），匿名可读，不用登录态：
- getNovelParagraphCommentNum：本章每段的评论数；paragraph_id 是「第几个非空段」（从 1 数），-2 是章末总评。
- getCommentList：某段的评论，offset / limit 翻页，新的在前。
章节 HTML 的段落就是非空行逐个包成 <p>（Text.textToBody），所以第 n 个 <p> 就是 paragraph_id = n。

@module koplugin.book.source.jjwxc.reviews
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Reviews = {}

local BASE = "https://www.jjwxc.net/app.jjwxc/Pc/comment/"
local VERSION = "489"
local PAGE_SIZE = 20
-- 气泡跟在段末：只用段尾这么多个字定位（要唯一），气泡画在最后一行右侧。
local MARK_RUNES = 24

---@class JjwxcReviewHotspot
---@field range string 段落序号（第几个非空段）
---@field text string
---@field total integer 本段评论数

---@param name string
---@param query string
---@param novel_id string
---@param chapter_id string
---@param cb fun(data: table|nil, err: string|nil)
---@return HttpJob
local function get(name, query, novel_id, chapter_id, cb)
    local referer = "https://www.jjwxc.net/onebook.php?novelid=" .. novel_id .. "&chapterid=" .. chapter_id
    return Request.get(BASE .. name .. "?versionCode=" .. VERSION .. query, {
        accept = "application/json",
        headers = { ["User-Agent"] = "Mozilla/5.0", Referer = referer, versionCode = VERSION },
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then cb(nil, _("响应无效")); return end
        if tostring(wire.code) ~= "200" or type(wire.data) ~= "table" then
            cb(nil, tostring(wire.message or _("晋江段评请求失败")))
            return
        end
        cb(wire.data)
    end)
end

--- 统计回包 → 有评论的段落（未定位）；章末总评（-2）不是段，丢弃。
---@param data table
---@return JjwxcReviewHotspot[]
function Reviews.hotspots(data)
    local out = {}
    for _idx, row in ipairs(data) do
        local pid, total = tonumber(row.paragraph_id), tonumber(row.comment_total) or 0
        if pid and pid > 0 and total > 0 then
            out[#out + 1] = { range = tostring(pid), text = "", total = total }
        end
    end
    table.sort(out, function(a, b) return tonumber(a.range) < tonumber(b.range) end)
    return out
end

--- 评论表情是「[紫糖]」这样的文字标记，原样保留；正文里偶有 HTML 实体 / 换行标签。
---@param row table
---@return WechatReview
function Reviews.item(row)
    local body = Text.xmlDecode((tostring(row.commentBody or ""):gsub("<[Bb][Rr]%s*/?>", "\n")))
    return {
        id = tostring(row.commentId or ""),
        author = tostring(row.commentAuthor or ""),
        content = Text.trim(body),
        likes = tonumber(row.agreenum) or 0,
        images = {},
        time = tonumber(row.comment_date_time) or 0,
    }
end

--- 评论回包 → 一页；offset 即游标（首页 0）。
---@param data table
---@param offset integer
---@return WechatReviewPage|nil, string|nil
function Reviews.page(data, offset)
    local list = data.commentList
    if type(list) ~= "table" then return nil, _("晋江段评响应缺少评论列表") end
    local items = {}
    for _idx, row in ipairs(list) do
        if type(row) == "table" then items[#items + 1] = Reviews.item(row) end
    end
    local total = tonumber(data.commentTotal) or #items
    local next_offset = offset + #items
    return { items = items, total = total, max_idx = next_offset, more = #items > 0 and next_offset < total }
end

--- 本章有评论的段落。
---@param novel_id string
---@param chapter_id string
---@param cb fun(hotspots: JjwxcReviewHotspot[]|nil, err: string|nil)
---@return HttpJob
function Reviews.hotspotsAsync(novel_id, chapter_id, cb)
    return get("getNovelParagraphCommentNum", "&novelid=" .. novel_id .. "&chapterid=" .. chapter_id,
        novel_id, chapter_id, function(data, err)
            if not data then cb(nil, err); return end
            cb(Reviews.hotspots(data))
        end)
end

--- 某段的一页评论。
---@param novel_id string
---@param chapter_id string
---@param para_index integer
---@param offset integer
---@param cb fun(page: WechatReviewPage|nil, err: string|nil)
---@return HttpJob
function Reviews.pageAsync(novel_id, chapter_id, para_index, offset, cb)
    local query = string.format("&novelId=%s&chapterId=%s&paragraph_id=%d&offset=%d&limit=%d",
        novel_id, chapter_id, para_index, offset, PAGE_SIZE)
    return get("getCommentList", query, novel_id, chapter_id, function(data, err)
        if not data then cb(nil, err); return end
        cb(Reviews.page(data, offset))
    end)
end

--- 取串尾最多 n 个字（UTF-8 按首字节计，不会切坏字符）。
---@param s string
---@param n integer
---@return string
local function tail(s, n)
    local count, at = 0, #s + 1
    while at > 1 and count < n do
        at = at - 1
        while at > 1 and s:byte(at) >= 0x80 and s:byte(at) < 0xC0 do at = at - 1 end
        count = count + 1
    end
    return s:sub(at)
end

--- 章节 HTML 里每个非空段的纯文本，键为第几个非空段。
---@param html string
---@return table<string, string>
local function paragraphs(html)
    local out, n = {}, 0
    for seg in html:gmatch("<p[%s>].-</p>") do
        local text = Text.trim((Text.stripHtml(seg):gsub("\n", "")))
        if text ~= "" then
            n = n + 1
            out[tostring(n)] = text
        end
    end
    return out
end

--- 把有评论的段落定位到章节 HTML：按段末文字找 xpointer，同文重复按段序消歧，仍无法消歧的丢弃。
--- 返回的 text 是整段原文（评论页上方的引用）。
---@param hotspots JjwxcReviewHotspot[]
---@param html string
---@return table[] spots { range, text, total, pos0, pos1, badge }
function Reviews.locate(hotspots, html)
    local paras = paragraphs(html)
    local items = {}
    for _idx, hotspot in ipairs(hotspots) do
        local text = paras[hotspot.range]
        if text then
            items[#items + 1] = { text = tail(text, MARK_RUNES), wr_range = hotspot.range, hotspot = hotspot, full = text }
        end
    end
    local located = require("book.annotations").locateBatch(html, items)
    local out = {}
    for _idx, entry in ipairs(items) do
        local hit = located[entry]
        if hit then
            local hotspot = entry.hotspot
            out[#out + 1] = {
                range = hotspot.range, text = entry.full, total = hotspot.total, pos0 = hit.pos0, pos1 = hit.pos1,
                badge = hotspot.total > 99 and "99+" or tostring(hotspot.total),
            }
        end
    end
    return out
end

return Reviews
