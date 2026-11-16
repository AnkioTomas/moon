--[[--
潇湘书院元数据搜索：匿名访问新站 JSON 接口 /api/xxsy/bookstore/web/search（Cookie 与 _csrfToken 同值即可，免签名）

@module koplugin.book.desktop.detail.scrape.platform.xiaoxiang
--]]

local JSON = require("utils.json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Xiaoxiang = {}

local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"

--- 书 id 是 17 位整数，超出 double 精度，解码前先加引号。
---@param raw string
---@return table|nil
local function decode(raw)
    local quoted = raw:gsub('("[%w_]+"%s*:%s*)(%d+)([,}%]%s])', function(key, value, tail)
        return key .. (#value >= 16 and ('"' .. value .. '"') or value) .. tail
    end)
    local ok, wire = pcall(JSON.decode, quoted)
    return ok and type(wire) == "table" and wire or nil
end

---@param list table
---@return table[]
function Xiaoxiang.rows(list)
    local books, tags = {}, {}
    for _idx, row in ipairs(list) do
        local id = row.cbid or row.cbId
        if type(row) == "table" and type(id) == "string" and id:match("^%d+$") and type(row.title) == "string" then
            local names = {}
            for _i, tag in ipairs(type(row.bookTagInfo) == "table" and row.bookTagInfo or {}) do
                if type(tag) == "table" and type(tag.tagName) == "string" and tag.tagName ~= "" then
                    names[#names + 1] = tag.tagName
                end
            end
            books[#books + 1] = {
                title = row.title,
                authors = type(row.author) == "string" and row.author or "",
                category = type(row.catel2name) == "string" and row.catel2name or "",
                intro = type(row.intro) == "string" and (row.intro:gsub("\r", "")) or "",
                cover = "https://bookcover.yuewen.com/qdbimg/349573/c_" .. id .. "/180",
            }
            tags[#books] = names
        end
    end
    local out = Novel.fromBooks("xiaoxiang", books)
    for idx, item in ipairs(out) do
        if #tags[idx] > 0 then item.tags = tags[idx] end
    end
    return out
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return table|nil
function Xiaoxiang.searchAsync(query, cb)
    local url = "https://www.xxsypro.com/api/xxsy/bookstore/web/search?key=" .. Text.urlEncode(query)
        .. "&start=0&n=20&_csrfToken=moon"
    return Request.get(url, {
        accept = "application/json",
        headers = { Cookie = "csrfToken=moon", Referer = "https://www.xxsypro.com/", ["User-Agent"] = UA },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("xiaoxiang search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local wire = decode(raw)
        local data = wire and wire.code == 0 and type(wire.data) == "table" and wire.data.searchData
        if type(data) ~= "table" or type(data.cardList) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        cb(Xiaoxiang.rows(data.cardList))
    end)
end

return Xiaoxiang
