--[[--
豆瓣阅读：搜索体、正文解密、专栏目录、扫码登录和书架。

@module tests.source.douban.client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

package.preload["json"] = function() return require("support.json_stub") end

local Aes = require("crypto.aes")
local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Json = require("support.json_stub")
local Text = require("utils.text")
local Mapper = require("source.douban.mapper")

local cfg = {}
package.preload["utils.settings"] = function()
    return {
        getSource = function() return cfg end,
        saveSource = function() end,
        get = function() return {} end,
    }
end

local sha2 = require("ffi/sha2")
local iv = string.rep("\1", 16)
local plain = Json.encode({
    posts = { {
        title = "序",
        contents = {
            { type = "headline", id = 10, data = { text = "标题" } },
            { type = "paragraph", id = 11, data = { text = {
                { kind = "plaintext", content = "第一" },
                { kind = "plaintext", content = "段" },
            } } },
            { type = "pagebreak", id = 11.5, data = {} },
            { type = "paragraph", id = 12, data = { text = "第二段" } },
        },
    } },
    toc = {
        { title = "开篇", paragraph_id = 10, level = 0 },
        { title = "", paragraph_id = 12, level = 1 },
    },
})

local function seal(user_id)
    local material = user_id or "anonymous"
    local key = sha2.hex_to_bin(sha2.sha256(material))
    return Text.base64Encode(Aes.cbc_encrypt(plain, key, iv) .. iv .. string.rep("z", 13))
end

local article = Mapper.decrypt(seal(nil), nil)
Assert.eq(article.posts[1].title, "序")
Assert.eq(Mapper.blocksText(article, 10, 12), "标题\n第一段")
Assert.eq(Mapper.paragraphIds(article, 10, 12)[1], "10")
Assert.eq(Mapper.paragraphIds(article, 10, 12)[2], "11")
Assert.eq(#Mapper.paragraphIds(article, 10, 12), 2)
local spots = Mapper.reviewHotspots({
    { id = "1", note = "好看", startContainerId = "11", n_favorites = 3, owner = { name = "甲" }, create_time = 1700000000000 },
    { note = "", startContainerId = "11" },
    { note = "章外", startContainerId = "99" },
}, { "10", "11" })
Assert.eq(#spots, 1)
Assert.eq(spots[1].range, "2")
Assert.eq(spots[1].total, 1)
local page = Mapper.reviewPage({
    { id = "1", note = "好看", startContainerId = "11", n_favorites = 3, owner = { name = "甲" }, create_time = 1700000000000 },
}, { "10", "11" }, "2")
Assert.eq(page.items[1].author, "甲")
Assert.eq(page.items[1].content, "好看")
Assert.eq(page.items[1].likes, 3)
Assert.eq(page.items[1].time, 1700000000)
local dated = Mapper.reviewPage({
    { id = "2", note = "日期", startContainerId = "10", owner = { name = "乙" }, create_time = "2024-01-02T00:00:00+00:00" },
}, { "10" }, "1")
Assert.eq(os.date("!%Y-%m-%d", dated.items[1].time), "2024-01-02")
Assert.eq(page.total, 1)
Assert.eq(Mapper.blocksText(article, nil, nil), "标题\n第一段\n第二段")
Assert.eq(Mapper.decrypt(seal("42"), "42").posts[1].title, "序")
Assert.is_nil(Mapper.decrypt(seal("42"), nil))

local chapters = Mapper.ebookChapters(article, "594929245")
Assert.eq(#chapters, 2)
Assert.eq(chapters[1].uid, "10")
Assert.eq(chapters[1].title, "开篇")
Assert.eq(chapters[1].vip, false)
Assert.eq(chapters[1].slice, true)
Assert.eq(chapters[1].end_pid, "12")
Assert.eq(chapters[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(chapters[2].title, "第 2 章")
Assert.eq(chapters[2].vip, false)
Assert.is_nil(chapters[2].end_pid)

local rich = { posts = { { contents = {
    { id = 1, type = "paragraph", data = { text = {
        { kind = "plaintext", content = " 前文 " }, { kind = "plaintext", content = " 后文 " },
    } } },
    { id = 2, type = "paragraph", data = { text = {} } },
    { id = 3, type = "paragraph", data = { text = { { kind = "plaintext", content = " \n " } } } },
    { id = 4, type = "paragraph", data = { text = "尾段" } },
} } }, toc = { { paragraph_id = 1, title = "开篇" }, { paragraph_id = 4, title = "结尾" } } }
Assert.eq(Mapper.blocksText(rich), "前文  后文\n尾段")
Assert.eq(Mapper.blocksText(rich, 1, 4), "前文  后文")
Assert.eq(Mapper.paragraphIds(rich)[1], "1")
Assert.eq(Mapper.paragraphIds(rich)[2], "4")
Assert.eq(#Mapper.paragraphIds(rich), 2)
Assert.eq(Mapper.ebookChapters(rich, "test")[1].vip, false)

local found = Mapper.searchBooks({
    list = {
        { id = "594929245", title = "三体", author = { { name = "刘慈欣" } }, cover = "//pic/a.jpg", abstract = "科幻", url = "/ebook/594929245/", kinds = { { shortName = "科幻" } } },
        { id = "1", title = "有声", isAudio = true },
        { id = "699209652", title = "如果爱", isColumn = true, url = "/column/73610846/", author = { { name = "茉莉多丁" } } },
    },
})
Assert.eq(#found, 2)
Assert.eq(found[1].stable_id, "594929245")
Assert.eq(found[1].authors, "刘慈欣")
Assert.eq(found[1].cover, "https://pic/a.jpg")
Assert.eq(found[1].category, "科幻")
Assert.eq(found[2].stable_id, "699209652")
Assert.is_nil(Mapper.searchBooks({ error = "PublishError" }))

local target = Mapper.reader("/reader/column/73610846/chapter/699210556/")
Assert.eq(target.kind, "column")
Assert.eq(target.column_id, "73610846")
Assert.eq(Mapper.reader("/reader/ebook/594929245/").kind, "ebook")
Assert.eq(Mapper.readerUrl({ data = { works = { readerUrl = "/reader/ebook/594929245/" } } }), "/reader/ebook/594929245/")

local column = Mapper.columnBook("699209652", {
    type = "column",
    title = "如果爱",
    abstract = "简介",
    cover = "https://pic/c.jpg",
    category = "言情小说",
    agent = { name = "茉莉多丁" },
    chapters = {},
})
Assert.eq(column.stable_id, "699209652")
Assert.eq(column.authors, "茉莉多丁")
Assert.eq(column.category, "言情小说")

local toc = Mapper.columnChapters({
    chapters = {
        { id = "699210556", title = "第一章", is_free = true },
        { id = "699210557", title = "第二章", is_free = false, is_paid = false, is_allowed_to_read = false },
        { id = "699210558", title = "第三章", is_paid = true },
    },
})
Assert.eq(#toc, 3)
Assert.eq(toc[1].content_url, "699210556")
Assert.eq(toc[1].vip, false)
Assert.eq(toc[1].toc_version, Mapper.TOC_VERSION)
Assert.eq(toc[2].vip, true)
Assert.eq(toc[3].vip, false)

local shelf = Mapper.shelf({ list = { { id = "9", title = "书架书", author = { { name = "甲" } } } } })
Assert.eq(shelf[1].stable_id, "9")
Assert.eq(#Mapper.shelf({}), 0)
Assert.eq(#Mapper.shelf({ worksIds = {} }), 0)
Assert.is_nil(Mapper.shelf({ worksIds = { "9" } }))
Assert.is_nil(Mapper.shelf({ error = "Nope" }))
Assert.is_nil(Mapper.shelf({ list = { { foo = 1 } } }))
Assert.eq(#Mapper.shelfIds({ worksIds = {} }), 0)
Assert.eq(Mapper.shelfIds({ worksIds = { "9" } })[1], "9")
Assert.eq(Mapper.shelfIds({ data = { user = { bookshelf = { libraryList = { list = { { worksId = "9" } } } } } } })[1], "9")
Assert.is_nil(Mapper.shelfIds({ error = "Nope" }))
local shelf_rows = Mapper.shelfWorks({
    data = { worksList = { { id = "9", title = "书架书", author = { { name = "甲" } }, cover = "https://img/a.jpg" } } },
})
Assert.eq(shelf_rows[1].stable_id, "9")
Assert.eq(shelf_rows[1].title, "书架书")
Assert.eq(shelf_rows[1].authors, "甲")
Assert.eq(shelf_rows[1].cover, "https://img/a.jpg")
Assert.is_nil(Mapper.shelfWorks({ data = { worksList = { { id = "1", title = "听", isAudio = true } } } }))
Assert.eq(Mapper.readCsrf("CSRF_TOKEN = 'shelf-tok';"), "shelf-tok")

Assert.eq(Mapper.csrf('<meta name="csrf-token" content="tok123">'), "tok123")
local user = Mapper.user('Ark.user = {"id":"42","name":"读","isAnonymous":false}')
Assert.eq(user.id, "42")
Assert.eq(user.name, "读")
Assert.is_nil(Mapper.user('Ark.user = {"isAnonymous": true}'))

local ticket = Mapper.qr({ url = "/oidc/qrcode/confirm?code=abc", expires_in = 300 }, "https://accounts.arkread.com")
Assert.eq(ticket.qr, "https://accounts.arkread.com/oidc/qrcode/confirm?code=abc")
Assert.eq(ticket.code, "abc")
Assert.eq(Mapper.qrStatus({ confirmed = false }), "wait")
Assert.eq(Mapper.qrStatus({ confirmed = true }), "ok")
local progress = Mapper.progress({ r = 0, progress = { paragraph_id = 10, paragraph_offset = 0 } })
Assert.eq(progress.paragraph_id, "10")
Assert.eq(select(2, Mapper.progress({ r = 1 })), false)
Assert.eq(select(2, Mapper.progress({ progress = {} })), false)
Assert.eq(select(2, Mapper.progress({ r = 0 })), true)
Assert.eq(Mapper.firstParagraphId({
    posts = { { contents = { { id = 3, type = "headline" }, { id = 4, type = "paragraph", data = { text = "正文" } } } } },
}), "4")
Assert.eq(Mapper.searchBody("三体").extensions.persistedQuery.sha256Hash, Mapper.SEARCH_HASH)

local requests = {}
local authorize_hits = 0
local deferred_requests, defer_column = false, false
local progress_write_body = Json.encode({ r = 0 })
package.preload["http.request"] = function()
    return {
        header = function(res, name)
            local headers = res and res.headers or {}
            for key, value in pairs(headers) do
                if key:lower() == name:lower() then return value end
            end
        end,
        headerAll = function(res, name)
            local headers = res and res.headers or {}
            local found = {}
            for key, value in pairs(headers) do
                if key:lower() == name:lower() and type(value) == "string" then found[#found + 1] = value end
            end
            return found
        end,
        request = function(opts, callback)
            local request = { method = opts.method, url = opts.url, body = opts.body, headers = opts.headers }
            requests[#requests + 1] = request
            local res = { code = 200, body = "{}", headers = {} }
            if opts.url:find("/j/search_v2", 1, true) then
                res.body = Json.encode({ list = { { id = "594929245", title = "三体", author = { { name = "刘慈欣" } } } } })
            elseif opts.url:find("/j/graphql", 1, true) and opts.body and opts.body:find(Mapper.ACCESS_HASH, 1, true) then
                local works_id = opts.body:match('"worksId":"(%d+)"')
                local reader = works_id == "699209652" and "/reader/column/73610846/chapter/699210556/" or "/reader/ebook/594929245/"
                res.body = Json.encode({ data = { works = { readerUrl = reader } } })
            elseif opts.url:find("/j/column/73610846/", 1, true) then
                res.body = Json.encode({
                    type = "column", title = "如果爱", abstract = "简介", agent = { name = "茉莉多丁" },
                    chapters = { { id = "699210556", title = "第一章", is_free = true } },
                })
            elseif opts.body and opts.body:find(Mapper.INFO_HASH, 1, true) then
                res.body = Json.encode({ data = { universalWorks = { id = "594929245", title = "三体", isColumn = false } } })
            elseif opts.body and opts.body:find(Mapper.SHELF_WORKS_HASH, 1, true) then
                res.body = Json.encode({
                    data = { worksList = { { id = "9", title = "书架书", author = { { name = "甲" } }, cover = "https://img/a.jpg" } } },
                })
            elseif opts.url:find("get_reader_data", 1, true) then
                res.body = Json.encode({ r = 0, data = seal(nil), readerDataVersion = "v24" })
            elseif opts.url:find("/oidc/login", 1, true) then
                res.code = 302
                res.headers.Location = "https://accounts.arkread.com/oauth2/authorize?client_id=public"
            elseif opts.url:find("/oauth2/authorize", 1, true) then
                authorize_hits = authorize_hits + 1
                if authorize_hits == 1 then
                    res.body = '<meta name="csrf-token" content="tok123">Ark.user = {"isAnonymous": true}'
                else
                    res.code = 302
                    res.headers.Location = "https://read.douban.com/"
                end
            elseif opts.url:find("/oidc/qrcode/generate", 1, true) then
                if opts.headers.Referer ~= "https://accounts.arkread.com/" then
                    res.code = 400
                    res.body = Json.encode({ code = 1002, message = "The referrer header is missing." })
                else
                    res.body = Json.encode({ url = "/oidc/qrcode/confirm?code=abc", expires_in = 300 })
                end
            elseif opts.url:find("/oidc/qrcode/status", 1, true) then
                if opts.headers.Referer ~= "https://accounts.arkread.com/" then
                    res.code = 400
                    res.body = Json.encode({ code = 1002, message = "The referrer header is missing." })
                else
                    res.body = Json.encode({ confirmed = false })
                end
            elseif opts.url == "https://read.douban.com/" then
                res.body = 'CSRF_TOKEN = \'shelf-tok\'; Ark.user = {"id":"42","name":"读","isAnonymous":false}'
                res.headers["Set-Cookie"] = "session=s1; Path=/"
            elseif opts.url:find("/j/progress/", 1, true) and opts.method == "GET" then
                res.body = Json.encode({ r = 0, progress = { paragraph_id = "10", paragraph_offset = 0 } })
            elseif opts.url:find("/j/progress/", 1, true) then
                res.body = progress_write_body
            elseif opts.url:find("/j/reading_time", 1, true) then
                res.body = ""
            elseif opts.url:find("/annotations_by_paragraphs", 1, true) then
                res.body = '['
                    .. '{"id":"1","note":"好看","startContainerId":"11","n_favorites":2,"owner":{"name":"甲"},"create_time":1700000000},'
                    .. '{"note":"","startContainerId":"10"}'
                    .. ']'
            elseif opts.url:find("/j/bookshelf/folder/", 1, true) then
                res.body = Json.encode({ folderIds = {} })
            elseif opts.url:find("/j/bookshelf/", 1, true) and opts.method == "GET" then
                res.body = Json.encode({ worksIds = { "9" } })
            elseif opts.url:find("/j/bookshelf/", 1, true) then
                res.body = Json.encode({ ok = true })
            end
            request.reply = function() callback(res, nil) end
            if not deferred_requests and not (defer_column and opts.url:find("/j/column/", 1, true)) then
                request.reply()
            end
            return { cancel = function() request.cancelled = true end }
        end,
    }
end

local Client = require("source.douban.client")

local books
Client.searchAsync("三体", function(list) books = list end)
Assert.eq(books[1].title, "三体")
Assert.is_true(requests[#requests].body:find(Mapper.SEARCH_HASH, 1, true) ~= nil)
Assert.eq(requests[#requests].method, "POST")

local detail
Client.detailAsync("699209652", function(book) detail = book end)
Assert.eq(detail.title, "如果爱")
Assert.eq(detail.authors, "茉莉多丁")
Assert.eq(detail.stable_id, "699209652")

local ebook
Client.detailAsync("594929245", function(book) ebook = book end)
Assert.eq(ebook.title, "三体")

local toc_rows
Client.tocAsync("594929245", function(rows) toc_rows = rows end)
Assert.eq(toc_rows[1].title, "开篇")
local reader_hits = 0
for _idx, req in ipairs(requests) do
    if req.url:find("get_reader_data", 1, true) then reader_hits = reader_hits + 1 end
end
Assert.eq(reader_hits, 1)

local text
Client.textAsync("594929245", 10, 12, function(value) text = value end)
Stubs.flush()
Assert.eq(text, "标题\n第一段")
local reader_hits_after = 0
for _idx, req in ipairs(requests) do
    if req.url:find("get_reader_data", 1, true) then reader_hits_after = reader_hits_after + 1 end
end
Assert.eq(reader_hits_after, 1)

local denied
Client.shelfAsync(function(_rows, err) denied = err end)
Stubs.flush()
Assert.eq(denied, "未登录豆瓣阅读")

local ticket
local login = Client.newLogin()
login:beginQrAsync(function(value) ticket = value end)
Assert.eq(ticket.code, "abc")
Assert.eq(ticket.qr, "https://accounts.arkread.com/oidc/qrcode/confirm?code=abc")
Assert.eq(ticket.authorize, "https://accounts.arkread.com/oauth2/authorize?client_id=public")
Assert.eq(requests[#requests].headers["X-CSRF-Token"], "tok123")

local waiting
login:qrStatusAsync("abc", function(kind) waiting = kind end)
Assert.eq(waiting, "wait")

local logged
login:finishQrAsync(ticket.authorize, function(value) logged = value end)
Assert.eq(logged.id, "42")
Assert.eq(cfg.logged_in, true)
Assert.eq(cfg.user_id, "42")
Assert.eq(cfg.name, "读")
Assert.is_true(cfg.cookie:find("session=s1", 1, true) ~= nil)

local shelf_books
Client.shelfAsync(function(list) shelf_books = list end)
Assert.eq(shelf_books[1].title, "书架书")
Assert.eq(shelf_books[1].authors, "甲")
Assert.eq(requests[#requests].headers["X-CSRF-Token"], "shelf-tok")
Assert.is_true(requests[#requests].body:find(Mapper.SHELF_WORKS_HASH, 1, true) ~= nil)

local added
Client.addAsync("9", function(ok) added = ok end)
Assert.eq(added, true)
Assert.eq(requests[#requests].method, "POST")
Assert.is_true(requests[#requests].body:find("9", 1, true) ~= nil)

local removed
Client.removeAsync("9", function(ok) removed = ok end)
Assert.eq(removed, true)
Assert.eq(requests[#requests].method, "DELETE")

local progress_mark
Client.progressAsync("9", function(value) progress_mark = value end)
Assert.eq(progress_mark.paragraph_id, "10")
Assert.is_true(requests[#requests].url:find("works_id=9", 1, true) ~= nil)

local progress_saved
Client.putProgressAsync("9", "10", 2, 4, true, function(ok) progress_saved = ok end)
Assert.eq(progress_saved, true)
Assert.eq(requests[#requests].method, "POST")
Assert.is_true(requests[#requests].url:find("/j/progress/", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("percentage=25", 1, true) ~= nil)
Assert.eq(requests[#requests].headers["Content-Type"], "application/x-www-form-urlencoded")

local progress_failure
progress_write_body = Json.encode({ r = 1 })
Client.putProgressAsync("9", "10", 2, 4, true, function(ok, err)
    progress_saved, progress_failure = ok, err
end)
Assert.is_nil(progress_saved)
Assert.eq(progress_failure, "豆瓣阅读进度保存失败")
progress_write_body = "<html>upstream error</html>"
Client.putProgressAsync("9", "10", 2, 4, true, function(ok, err)
    progress_saved, progress_failure = ok, err
end)
Assert.is_nil(progress_saved)
Assert.eq(progress_failure, "豆瓣阅读进度保存失败")
progress_write_body = Json.encode({ r = 0 })

local reading_saved
Client.pushReadingAsync({
    { worksId = 9, beginTime = "2020-01-01T00:00:00.000Z", endTime = "2020-01-01T00:01:00.000Z" },
}, function(ok) reading_saved = ok end)
Assert.eq(reading_saved, true)
Assert.is_true(requests[#requests].url:find("/j/reading_time", 1, true) ~= nil)
Assert.is_true(requests[#requests].body:find("worksId", 1, true) ~= nil)

local noted
Client.annotationsAsync("594929245", { "10", "11" }, function(rows) noted = rows end)
Assert.eq(#noted, 2)
Assert.eq(requests[#requests].method, "POST")
Assert.is_true(requests[#requests].url:find("/j/article_v2/594929245/annotations_by_paragraphs", 1, true) ~= nil)
Assert.eq(requests[#requests].body, "paragraph_ids=10%2C11")
Assert.eq(Mapper.reviewHotspots(noted, { "10", "11" })[1].range, "2")

cfg.cookie, cfg.logged_in, cfg.user_id = nil, nil, nil
Client.reset()
local cached_article
Client.articleAsync("cached", function(value) cached_article = value end)
Assert.is_true(cached_article ~= nil)
local cache_calls = 0
local cache_job = Client.articleAsync("cached", function() cache_calls = cache_calls + 1 end)
Assert.eq(cache_calls, 0)
cache_job.cancel()
Stubs.flush()
Assert.eq(cache_calls, 0)
Client.articleAsync("cached", function() cache_calls = cache_calls + 1 end)
Stubs.flush()
Assert.eq(cache_calls, 1)

deferred_requests = true
for _idx, method in ipairs({ "detailAsync", "tocAsync" }) do
    for cancel_at = 0, 1 do
        local calls = 0
        local job = Client[method]("699209652", function() calls = calls + 1 end)
        local active = requests[#requests]
        if cancel_at == 1 then
            active.reply()
            active = requests[#requests]
        end
        local count = #requests
        job.cancel()
        Assert.is_true(active.cancelled)
        active.reply()
        Stubs.flush()
        Assert.eq(calls, 0)
        Assert.eq(#requests, count)
    end
end

deferred_requests, defer_column = false, true
local sync_calls = 0
local sync_job = Client.detailAsync("699209652", function() sync_calls = sync_calls + 1 end)
local second = requests[#requests]
sync_job.cancel()
Assert.is_true(second.cancelled)
second.reply()
Assert.eq(sync_calls, 0)
defer_column, deferred_requests = false, true

cfg.cookie, cfg.logged_in, cfg.user_id = "session=s1", true, "42"
for cancel_at = 0, 2 do
    Client.reset()
    local calls = 0
    local job = Client.shelfAsync(function() calls = calls + 1 end)
    local active = requests[#requests]
    for _step = 1, cancel_at do
        active.reply()
        active = requests[#requests]
    end
    local count = #requests
    job.cancel()
    Assert.is_true(active.cancelled)
    active.reply()
    Assert.eq(calls, 0)
    Assert.eq(#requests, count)
end

for cancel_at = 0, 2 do
    authorize_hits = 0
    local calls = 0
    local job = Client.newLogin():beginQrAsync(function() calls = calls + 1 end)
    local active = requests[#requests]
    for _step = 1, cancel_at do
        active.reply()
        active = requests[#requests]
    end
    local count = #requests
    job.cancel()
    Assert.is_true(active.cancelled)
    active.reply()
    Assert.eq(calls, 0)
    Assert.eq(#requests, count)
end

authorize_hits = 1
local finish_calls = 0
local finish_job = Client.newLogin():finishQrAsync("https://accounts.arkread.com/oauth2/authorize?client_id=public",
    function() finish_calls = finish_calls + 1 end)
requests[#requests].reply()
local final = requests[#requests]
finish_job.cancel()
Assert.is_true(final.cancelled)
final.reply()
Assert.eq(finish_calls, 0)
