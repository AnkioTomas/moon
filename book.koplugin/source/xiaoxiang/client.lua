--[[--
潇湘书院 HTTP 客户端（仅异步）。

搜索走 PC 站搜索页（HTML）；目录和章节走手机站 SSR 页面（m.xxsy.net，目录内嵌 JSON、章节正文在 #content）。
免费章匿名可读，没买的 VIP 章页面只有预览；登录态是手机站 Cookie（setting.lua 让用户粘贴），已购 VIP 章带 Cookie 才有正文。目录页上千章、1MB+，解析放子进程。

@module koplugin.book.source.xiaoxiang.client
--]]

local Job = require("workers.job")
local Mapper = require("source.xiaoxiang.mapper")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

--- 已保存的登录 Cookie。
---@return string|nil
function Client.cookie()
    local cookie = require("utils.settings").getSource("xiaoxiang").cookie
    return type(cookie) == "string" and cookie ~= "" and cookie or nil
end

local UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    .. "Version/16.0 Mobile/15E148 Safari/604.1"

---@param url string
---@param cb fun(html: string|nil, err: string|nil)
---@return HttpJob
local function page(url, cb)
    return Request.get(url, {
        headers = { ["User-Agent"] = UA, Cookie = Client.cookie() },
        timeout = require("http.timeout").net(1),
    }, function(raw, err)
        if not raw then cb(nil, err and tostring(err) or _("请求失败")); return end
        cb(raw)
    end)
end

---@param keyword string
---@param cb fun(books: Book[]|nil, err: string|nil)
---@return HttpJob
function Client.searchAsync(keyword, cb)
    return page("https://www.xxsy.net/search?sort=0&s_wd=" .. Text.urlEncode(keyword), function(html, err)
        if not html then cb(nil, err); return end
        cb(Mapper.search(html))
    end)
end

--- 取页面并在子进程里按 parse 解析；parse 返回 nil 以外的值都算成功。
---@param url string
---@param name string
---@param parse fun(html: string): any, string|nil
---@param cb fun(value: any, err: string|nil, kind: string|nil)
---@return { cancel: fun() }
local function parsed(url, name, parse, cb)
    local cancelled, job = false, nil
    job = page(url, function(html, err)
        if cancelled then return end
        if not html then cb(nil, err); return end
        job = Job.run(function()
            local value, kind = parse(html)
            return { value = value, kind = kind }
        end, {
            name = name,
            kind = "light",
            timeout = 60,
            on_done = function(res)
                if cancelled then return end
                cb(res.value, nil, res.kind)
            end,
            on_failed = function(reason) if not cancelled then cb(nil, tostring(reason)) end end,
            on_cancelled = function() end,
        })
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param book_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(book_id, cb)
    return parsed("https://m.xxsy.net/books/" .. book_id .. ".html", "xiaoxiang_toc", Mapper.toc, cb)
end

--- 一章正文（纯文本，段落以换行分隔）。
---@param book_id string
---@param chapter_id string
---@param cb fun(text: string|nil, err: string|nil, kind: "unpaid"|nil)
---@return { cancel: fun() }
function Client.contentAsync(book_id, chapter_id, cb)
    return parsed("https://m.xxsy.net/chapter/" .. book_id .. "/" .. chapter_id, "xiaoxiang_content", Mapper.content,
        function(text, err, kind)
            if text then cb(text); return end
            cb(nil, err or _("潇湘章节内容为空"), kind)
        end)
end

return Client
