--[[--
阅读 App 段评映射。range 保存 { 段号, paraData }，评论 id 保存同一上下文及原始 id；
分页位置保存 { page, cursor }。这些不透明键随公共段评缓存落盘，不依赖源实例的临时状态。
段落按章节里的 moon-legado-paragraph-N 标记定位，图片或被丢弃的空段不能改变源站段号。

@module koplugin.book.source.legado.reviews
--]]

local JSON = require("json")
local Locate = require("book.review_locate")
local Text = require("utils.text")
local _ = require("l10n").get("source.legado")

local Reviews = {}

---@param range string
---@param reply boolean|nil
---@return table|nil, string|nil
function Reviews.context(range, reply)
    local ok, value = pcall(JSON.decode, range)
    if not ok or type(value) ~= "table" or type(value[1]) ~= "number"
        or (value[1] ~= -1 and (value[1] < 1 or value[1] % 1 ~= 0))
        or type(value[2]) ~= "string"
        or (reply and (type(value[3]) ~= "string" or value[3] == "")) then
        return nil, _("阅读段评位置无效")
    end
    return value
end

---@param data table
---@return table[]|nil, string|nil
function Reviews.hotspots(data)
    if type(data) ~= "table" or type(data.counts) ~= "table" or type(data.keys) ~= "table" then
        return nil, _("阅读段评响应无效")
    end
    local out = {}
    for key, count in pairs(data.counts) do
        local paragraph = tonumber(key)
        local value = data.keys[key]
        if not paragraph or paragraph % 1 ~= 0 or type(count) ~= "number" or count < 0 or count % 1 ~= 0
            or (value ~= nil and type(value) ~= "string") then
            return nil, _("阅读段评响应无效")
        end
        if (paragraph > 0 or paragraph == -1) and count > 0 then
            out[#out + 1] = {
                range = JSON.encode({ paragraph, value and value ~= "" and value or tostring(paragraph) }),
                paragraph = paragraph, text = "", total = count,
            }
        end
    end
    table.sort(out, function(a, b) return a.paragraph < b.paragraph end)
    return out
end

---@param max_idx integer|string
---@return integer|nil, string|nil, string|nil
function Reviews.pagination(max_idx)
    if max_idx == 0 then return 1 end
    local ok, value = pcall(JSON.decode, max_idx)
    if not ok or type(value) ~= "table" or type(value.page) ~= "number" or value.page < 1
        or value.page % 1 ~= 0 or (value.cursor ~= nil and type(value.cursor) ~= "string") then
        return nil, nil, _("阅读段评分页位置无效")
    end
    return value.page + 1, value.cursor
end

---@param data table
---@param context table
---@param page integer
---@return table|nil, string|nil
function Reviews.page(data, context, page)
    if type(data) ~= "table" or type(data.items) ~= "table" or type(data.hasMore) ~= "boolean"
        or (data.nextCursor ~= nil and type(data.nextCursor) ~= "string")
        or (#data.items == 0 and next(data.items) ~= nil) then
        return nil, _("阅读段评响应无效")
    end
    local items = {}
    for _idx, row in ipairs(data.items) do
        if type(row) ~= "table" or (row.content ~= nil and type(row.content) ~= "string")
            or (row.name ~= nil and type(row.name) ~= "string")
            or (row.id ~= nil and type(row.id) ~= "string") then
            return nil, _("阅读段评响应无效")
        end
        local images = {}
        if type(row.imageUrl) == "string" and row.imageUrl:match("^https?://") then
            images[1] = { url = row.imageUrl, width = 0, height = 0 }
        end
        local has_id = row.id ~= nil and row.id ~= ""
        items[#items + 1] = {
            id = has_id and JSON.encode({ context[1], context[2], row.id }) or "",
            author = row.name or "", content = Text.stripHtml(row.content or ""),
            time = type(row.time) == "string" and row.time or "",
            likes = tonumber(row.likeCount) or 0,
            replies = has_id and (tonumber(row.replyCount) or 0) or 0,
            reply_to = row.replyToName, images = images,
        }
    end
    return {
        items = items, total = #items == 0 and 0 or nil,
        max_idx = JSON.encode({ page = page, cursor = data.nextCursor }),
        more = #items > 0 and data.hasMore,
    }
end

---@param hotspots table[]
---@param html string
---@return table[]
function Reviews.locate(hotspots, html)
    local paras = {}
    for tag, body in html:gmatch("(<p%s+[^>]*>)(.-)</p>") do
        local paragraph = tag:match('id="moon%-legado%-paragraph%-(%d+)"')
        if paragraph then paras[paragraph] = Text.stripHtml(body) end
    end
    if #hotspots > 0 and next(paras) == nil then
        require("utils.log").warn("legado reviews: cached chapter has no paragraph anchors; download it again")
        return {}
    end
    local numbered, ranges = {}, {}
    for _idx, hotspot in ipairs(hotspots) do
        local paragraph = tostring(hotspot.paragraph)
        numbered[#numbered + 1] = { range = paragraph, total = hotspot.total }
        ranges[paragraph] = hotspot.range
    end
    local spots = Locate.locate(paras, numbered, html)
    for _idx, spot in ipairs(spots) do spot.range = ranges[spot.range] end
    return spots
end

return Reviews
