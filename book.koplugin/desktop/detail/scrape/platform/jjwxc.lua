--[[--
晋江文学城元数据搜索：匿名 App 接口 app-cdn.jjwxc.net/androidapi/search，无需登录，只取书名 / 作者 / 简介 / 封面 / 标签

@module koplugin.book.desktop.detail.scrape.platform.jjwxc
--]]

local JSON = require("json")
local Novel = require("desktop.detail.scrape.novel")
local Request = require("http.request")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("gettext")

local Jjwxc = {}

local SEARCH_URL = "https://app-cdn.jjwxc.net/androidapi/search"
local UA = "Mozilla/5.0 (Linux; Android 5.1; Lenovo) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 "
    .. "Chrome/39.0.0.0 Mobile Safari/537.36/JINJIANG-Android/206(Lenovo;android 5.1;Scale/2.0)"

local function str(value)
    return type(value) == "string" and value or ""
end

---@param wire table
---@return table[]
local function toRows(wire)
    local books, tags = {}, {}
    for _idx, item in ipairs(type(wire.items) == "table" and wire.items or {}) do
        if type(item) == "table" and str(item.novelname) ~= "" then
            local intro = str(item.novelintro) ~= "" and item.novelintro or item.novelintroshort
            -- 带 ver 参数的封面链接服务端强制 gzip，去掉才是原图
            local cover = str(item.ebookurl) ~= "" and item.ebookurl or item.cover
            books[#books + 1] = {
                title = item.novelname,
                authors = item.authorname,
                intro = type(intro) == "string" and Text.stripHtml(intro) or "",
                cover = str(cover):gsub("&ver=[^&]*", ""),
            }
            local list = {}
            for tag in str(item.tags):gmatch("%S+") do list[#list + 1] = tag end
            tags[#books] = list
        end
    end
    local rows = Novel.fromBooks("jjwxc", books)
    for idx, row in ipairs(rows) do row.tags = tags[idx] end
    return rows
end

---@param query string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return HttpJob
function Jjwxc.searchAsync(query, cb)
    local url = SEARCH_URL .. "?" .. Text.formEncode({ keyword = query, type = 1, page = 1, versionCode = 206 })
    return Request.get(url, {
        accept = "application/json",
        headers = { ["User-Agent"] = UA, ["Referer"] = "http://android.jjwxc.net?v=206" },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then
            logger.warn("jjwxc search error:", err)
            cb(nil, err and tostring(err) or _("请求失败"))
            return
        end
        local ok, wire = pcall(JSON.decode, raw)
        if not ok or type(wire) ~= "table" then
            cb(nil, _("响应无效"))
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

return Jjwxc
