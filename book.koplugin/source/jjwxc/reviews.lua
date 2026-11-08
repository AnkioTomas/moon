--[[--
晋江段评：本章各段评论数、某段的评论页、把段落定位到章节 HTML。

走晋江网页版的段评接口（www.jjwxc.net/app.jjwxc/Pc/comment/…），免费章节匿名可读，VIP 章节要登录态（当前协议的 commentAuth：web 带 Cookie，app 带 token 查询参数）：
- getNovelParagraphCommentNum：本章每段的评论数；paragraph_id 是「第几个非空段」（从 1 数），-2 是章末总评。
- getCommentList：某段的评论，offset / limit 翻页，新的在前。
章节 HTML 的段落就是非空行逐个包成 <p>（Text.textToBody），所以第 n 个 <p> 就是 paragraph_id = n。

@module koplugin.book.source.jjwxc.reviews
--]]

local JSON = require("json")
local Request = require("http.request")
local ReviewLocate = require("book.review_locate")
local Text = require("utils.text")
local _ = require("l10n").get("source.jjwxc")

local Reviews = {}

local BASE = "https://www.jjwxc.net/app.jjwxc/Pc/comment/"
local VERSION = "489"
local PAGE_SIZE = 20

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
    local headers = { ["User-Agent"] = "Mozilla/5.0", Referer = referer, versionCode = VERSION }
    -- 免费章节匿名可读，VIP 章节要登录态；没有任何登录态就匿名发。
    local protocol = require("source.jjwxc.protocols").current()
    local auth_query, auth_headers = "", {}
    if protocol then auth_query, auth_headers = protocol.commentAuth() end
    for key, value in pairs(auth_headers) do headers[key] = value end
    return Request.get(BASE .. name .. "?versionCode=" .. VERSION .. query .. auth_query, {
        accept = "application/json",
        headers = headers,
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

--- 统计回包 → 有评论的段落与章末（-2）；源入口按粒度分开。
---@param data table
---@return JjwxcReviewHotspot[]|nil, string|nil
function Reviews.hotspots(data)
    if next(data) and data[1] == nil then return nil, _("响应无效") end
    local out = {}
    for _idx, row in ipairs(data) do
        if type(row) ~= "table" then return nil, _("响应无效") end
        local pid, total = tonumber(row.paragraph_id), tonumber(row.comment_total)
        if not pid or not total or total < 0 then return nil, _("响应无效") end
        if (pid > 0 or pid == -2) and total > 0 then
            out[#out + 1] = { range = tostring(pid), text = "", total = total }
        end
    end
    table.sort(out, function(a, b) return tonumber(a.range) < tonumber(b.range) end)
    return out
end

--- 表情标记交给主题行内图片渲染；保留原文供离线缺图时显示。
---@param content string
---@return table<string, { url: string, headers: table<string, string> }>|nil
function Reviews.inlineImages(content)
    local emoticons = require("source.jjwxc.emoticons")
    local images = {}
    for placeholder in content:gmatch("%b[]") do
        local url = emoticons[placeholder]
        if url then images[placeholder] = { url = url, headers = { Referer = "https://www.jjwxc.net/" } } end
    end
    return next(images) and images or nil
end

--- 正文里偶有 HTML 实体 / 换行标签。
---@param row table
---@return WechatReview
function Reviews.item(row)
    local body = Text.stripHtml(row.commentBody)
    return {
        id = tostring(row.commentId or ""),
        author = tostring(row.commentAuthor or ""),
        content = body,
        inline_images = Reviews.inlineImages(body),
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
    if next(list) and list[1] == nil then return nil, _("晋江段评响应缺少评论列表") end
    local total = tonumber(data.commentTotal)
    if not total or total < 0 then return nil, _("晋江段评响应缺少评论列表") end
    local items = {}
    for _idx, row in ipairs(list) do
        if type(row) ~= "table" or not row.commentId then return nil, _("晋江段评响应缺少评论列表") end
        items[#items + 1] = Reviews.item(row)
    end
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

--- 把有评论的段落定位到章节 HTML。
---@param hotspots JjwxcReviewHotspot[]
---@param html string
---@return table[]
function Reviews.locate(hotspots, html)
    return ReviewLocate.locate(ReviewLocate.paragraphs(html), hotspots, html)
end

return Reviews
