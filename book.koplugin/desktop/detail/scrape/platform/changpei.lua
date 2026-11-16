--[[--
长佩文学元数据搜索：匿名访问官网 JSON 接口 /webapi/search/novels

@module koplugin.book.desktop.detail.scrape.platform.changpei
--]]

local JSON = require("utils.json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Changpei = {}

local API = "https://www.gongzicp.com/webapi"
local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    .. "Chrome/126.0.0.0 Safari/537.36"

---@param s any
---@return string
local function str(s)
    return type(s) == "string" and Text.trim(s) or ""
end

---@param list table
---@return table[]
function Changpei.rows(list)
    local books = {}
    for _idx, row in ipairs(list) do
        if type(row) == "table" and row.novel_id and str(row.novel_name) ~= "" then
            local cover = str(row.novel_cover)
            if cover:find("nocover", 1, true) then cover = "" end
            books[#books + 1] = {
                title = row.novel_name,
                authors = str(row.novel_author),
                category = str(row.novel_type),
                intro = str(row.novel_info) ~= "" and str(row.novel_info) or str(row.novel_desc),
                cover = (cover:gsub("%?.*$", "")),
                tags = type(row.novel_all_tag) == "table" and row.novel_all_tag or {},
            }
        end
    end
    local out = Novel.fromBooks("changpei", books)
    for idx, item in ipairs(out) do
        local tags = {}
        for _i, tag in ipairs(books[idx].tags) do
            if type(tag) == "string" and tag ~= "" then tags[#tags + 1] = tag end
        end
        if #tags > 0 then item.tags = tags end
    end
    return out
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return table|nil
function Changpei.searchAsync(query, cb)
    return Request.get(API .. "/search/novels?page=1&k=" .. Text.urlEncode(query), {
        accept = "application/json",
        headers = { Client = "pc", Referer = "https://www.gongzicp.com/", ["User-Agent"] = UA },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("changpei search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        local list = ok and type(wire) == "table" and tonumber(wire.code) == 200
            and type(wire.data) == "table" and wire.data.list
        if type(list) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        cb(Changpei.rows(list))
    end)
end

return Changpei
