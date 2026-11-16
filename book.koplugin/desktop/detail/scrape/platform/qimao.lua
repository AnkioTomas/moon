--[[--
七猫小说元数据搜索：匿名 App 接口 api-bc.wtzw.com/search/v1/words（请求头与查询参数各做一次 md5 签名），无需登录

@module koplugin.book.desktop.detail.scrape.platform.qimao
--]]

local JSON = require("json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Qimao = {}

local SEARCH_URL = "https://api-bc.wtzw.com/search/v1/words"
local SIGN_KEY = "d3dGiJc651gSQ8w1"

--- md5(按键名排序的 k=v 直接拼接 .. 密钥)
---@param params table<string, string>
---@return string
local function sign(params)
    local keys = {}
    for key in pairs(params) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for idx, key in ipairs(keys) do parts[idx] = key .. "=" .. params[key] end
    return require("ffi/sha2").md5(table.concat(parts) .. SIGN_KEY)
end

---@return table<string, string>
local function headers()
    local head = {
        ["AUTHORIZATION"] = "",
        ["app-version"] = "73720",
        ["application-id"] = "com.****.reader",
        ["channel"] = "unknown",
        ["net-env"] = "1",
        ["platform"] = "android",
        ["qm-params"] = "",
        ["reg"] = "0",
    }
    head.sign = sign(head)
    return head
end

---@param query string
---@return string
local function searchUrl(query)
    local params = {
        extend = "", tab = "0", gender = "0", refresh_state = "8",
        page = "1", wd = query, is_short_story_user = "0",
    }
    params.sign = sign(params)
    return SEARCH_URL .. "?" .. Text.formEncode(params)
end

local CDN = "https://cdn.wtzw.com"

---@param wire table
---@return table[]
local function toRows(wire)
    local data = type(wire.data) == "table" and wire.data or {}
    local books, tags = {}, {}
    for _idx, item in ipairs(type(data.books) == "table" and data.books or {}) do
        -- 高亮标签只出现在 title / author，原始值在 original_*
        local title = type(item) == "table" and (item.original_title or item.title)
        if type(title) == "string" and title ~= "" then
            local cover = type(item.image_link) == "string" and item.image_link or ""
            if cover:sub(1, 1) == "/" then cover = CDN .. cover end
            books[#books + 1] = {
                title = title,
                authors = item.original_author or item.author,
                intro = type(item.intro) == "string" and Text.stripHtml(item.intro) or "",
                cover = cover,
                meta = { rating = { score = tonumber(item.score) } },
            }
            local list = {}
            for tag in tostring(item.ptags or ""):gmatch("[^,]+") do list[#list + 1] = Text.trim(tag) end
            tags[#books] = list
        end
    end
    local rows = Novel.fromBooks("qimao", books)
    for idx, row in ipairs(rows) do row.tags = tags[idx] end
    return rows
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Qimao.searchAsync(query, cb)
    return Request.get(searchUrl(query), {
        accept = "application/json",
        headers = headers(),
        allow_redirects = true,
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("qimao search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        if type(wire.data) ~= "table" then
            local errors = wire.errors
            cb(nil, type(errors) == "table" and errors.title or _("请求失败"))
            return
        end
        local rows = toRows(wire)
        if #rows == 0 then
            cb(nil, _("无搜索结果"))
            return
        end
        cb(rows)
    end)
end

return Qimao
