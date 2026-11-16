--[[--
番茄小说元数据搜索：匿名访问 novel.snssdk.com 搜索接口（免签名、免 Cookie，需 App UA）

@module koplugin.book.desktop.detail.scrape.platform.fanqie
--]]

local JSON = require("utils.json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Fanqie = {}

local APP_UA = "com.dragon.read/6.5.3.32 (Linux; U; Android 13; zh_CN; VDE-AL10; Build/TP1A.220624.014;tt-ok/3.10.0.2)"
local COVER_CDN = "https://p6-novel.byteimg.com"

--- 签名封面链接会过期，收成 CDN 上的稳定路径。
---@param thumb any
---@return string
local function cover(thumb)
    if type(thumb) ~= "string" or thumb == "" then return "" end
    local path = thumb:match("(novel%-pic/[^~%?#]+)") or thumb:match("(novel%-static/[^~%?#]+)")
    if not path then return thumb:match("^https?://") and thumb or "" end
    return COVER_CDN .. "/" .. path .. "~tplv-shrink:320:0.image"
end

---@param list table
---@return Book[]
function Fanqie.books(list)
    local books = {}
    for _idx, row in ipairs(list) do
        if type(row) == "table" and row.book_id and type(row.title) == "string" then
            books[#books + 1] = {
                title = row.title,
                authors = type(row.author) == "string" and row.author or "",
                category = type(row.category) == "string" and row.category or "",
                intro = type(row.abstract) == "string" and row.abstract or "",
                cover = cover(row.thumb_url) ~= "" and cover(row.thumb_url) or cover(row.audio_thumb_uri),
            }
        end
    end
    return books
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return table|nil
function Fanqie.searchAsync(query, cb)
    local url = "https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?aid=1967&offset=0&q="
        .. Text.urlEncode(query)
    return Request.get(url, {
        accept = "application/json, text/plain, */*",
        headers = { ["User-Agent"] = APP_UA },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("fanqie search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        local list = ok and type(wire) == "table" and tonumber(wire.code) == 0
            and type(wire.data) == "table" and wire.data.ret_data
        if type(list) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        cb(Novel.fromBooks("fanqie", Fanqie.books(list)))
    end)
end

return Fanqie
