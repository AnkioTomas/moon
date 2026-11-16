--[[--
起点中文网元数据搜索：匿名访问手机站 /webcommon/search/list（双提交 CSRF：Cookie 与查询参数同一随机值）

@module koplugin.book.desktop.detail.scrape.platform.qidian
--]]

local JSON = require("utils.json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Qidian = {}

local WEB = "https://m.qidian.com"
local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"
local COVER = "https://bookcover.yuewen.com/qdbimg/349573/%s/180"

local csrf

--- 搜索结果 records → Book[]。作者名被站点截成「xx...」时留空。
---@param data table
---@return Book[]
function Qidian.books(data)
    local books = {}
    for _idx, row in ipairs(data.bookInfo.records) do
        if type(row) == "table" and row.bid and type(row.bName) == "string" then
            local author = row.bAuth
            books[#books + 1] = {
                title = row.bName,
                authors = type(author) == "string" and not author:find("%.%.%.$") and author or "",
                category = type(row.cat) == "string" and row.cat or "",
                intro = type(row.desc) == "string" and Text.stripHtml(row.desc) or "",
                cover = COVER:format(string.format("%.0f", tonumber(row.bid) or 0)),
            }
        end
    end
    return books
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return table|nil
function Qidian.searchAsync(query, cb)
    if not csrf then csrf = require("utils.random").hex(16) end
    local url = WEB .. "/webcommon/search/list?_csrfToken=" .. csrf
        .. "&kw=" .. Text.urlEncode(query) .. "&pageNum=1"
    return Request.get(url, {
        accept = "application/json",
        headers = {
            Cookie = "_csrfToken=" .. csrf,
            ["User-Agent"] = UA,
            Referer = WEB .. "/bookshelf/my/",
            Origin = WEB,
        },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("qidian search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        local data = ok and type(wire) == "table" and tonumber(wire.code) == 0 and wire.data
        if type(data) ~= "table" or type(data.bookInfo) ~= "table" or type(data.bookInfo.records) ~= "table" then
            cb(nil, _("响应无效"))
            return
        end
        cb(Novel.fromBooks("qidian", Qidian.books(data)))
    end)
end

return Qidian
