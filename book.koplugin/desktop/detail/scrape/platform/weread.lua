--[[--
微信读书元数据搜索：匿名网页接口 weread.qq.com/web/search/global，无需登录，只取书名 / 作者 / 简介 / 封面 / 出版社 / 评分

@module koplugin.book.desktop.detail.scrape.platform.weread
--]]

local JSON = require("json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Weread = {}

local SEARCH_URL = "https://weread.qq.com/web/search/global"

---@param wire table
---@return Book[]
local function toBooks(wire)
    local out = {}
    for _idx, item in ipairs(type(wire.books) == "table" and wire.books or {}) do
        local info = type(item) == "table" and item.bookInfo
        if type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
            -- newRating 是千分制（930 = 9.3 分）
            local rating = tonumber(info.newRating)
            out[#out + 1] = {
                title = info.title,
                authors = info.author,
                intro = info.intro,
                cover = info.cover,
                meta = {
                    publisher = info.publisher,
                    rating = rating and rating > 0 and { score = rating / 100 } or nil,
                },
            }
        end
    end
    return out
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Weread.searchAsync(query, cb)
    local url = SEARCH_URL .. "?" .. Text.formEncode({ keyword = query, count = 10 })
    return Request.get(url, {
        accept = "application/json",
        headers = { ["User-Agent"] = Request.randomUA() },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("weread search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        local rows = Novel.fromBooks("weread", toBooks(wire))
        if #rows == 0 then
            cb(nil, _("无搜索结果"))
            return
        end
        cb(rows)
    end)
end

return Weread
