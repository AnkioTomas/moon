--[[--
extensions/moonsource-kavita.koplugin：经源注册表发现；书架、开书（单卷 / 选卷 / 失败）、
封面、进度双向换算。HTTP 与书库全部打桩。

@module tests.extensions.kavita.source_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")

-- 往返桩：encode 登记表并发一个令牌串，decode 凭令牌取回（不是令牌就报错，同真解析器）。
local encoded = {}
local JSON = {
    encode = function(value)
        encoded[#encoded + 1] = value
        return "\0json" .. #encoded
    end,
    decode = function(text)
        return encoded[tonumber(text:match("^%z?json(%d+)$"))] or error("not json: " .. text)
    end,
}
package.loaded["json"] = JSON
Themed.install()
local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
-- 走 preload 不改 package.path：runner 只还原 preload/loaded，插件根上的 main.lua 会顶掉月读的 main。
for _idx, name in ipairs({ "client", "position", "source", "setting", "kamare" }) do
    package.preload["moonsource_kavita." .. name] = function()
        return dofile(PLUGIN .. "/moonsource_kavita/" .. name .. ".lua")
    end
end
-- 首页组件另有 on_deck_spec；这里只验证描述表把它交出去。
local on_deck = { id = "ext.kavita.on_deck" }
package.preload["moonsource_kavita.on_deck"] = function() return on_deck end

local cfg = { base_url = "http://kav/", api_key = " k ", libraries = { ["2"] = true, ["1"] = true } }
package.preload["utils.settings"] = function()
    local common = { active_source = "local" }
    return {
        get = function() return common end,
        save = function() end,
        getSource = function() return cfg end,
        saveSource = function() end,
    }
end
for _idx, id in ipairs({ "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }) do
    package.loaded["source." .. id] = {
        meta = function() return { id = id, name = id, type = "book" } end,
        new = function() return { id = id } end,
    }
end

local online = true
package.loaded["ui/network/manager"] = { isConnected = function() return online end }

-- HTTP：按 "METHOD /path" 路由；值为响应表或 fun(opts) → 响应表。
local routes, calls = {}, {}
local download = { code = 200, body = "PK\3\4epub" }
package.loaded["http.request"] = {
    ok = function(code)
        code = tonumber(code)
        return code ~= nil and code >= 200 and code < 300
    end,
    request = function(opts, cb)
        calls[#calls + 1] = opts
        local route = routes[opts.method .. " " .. opts.url:match("^http://kav(/[^?]*)")]
        require("ui/uimanager"):nextTick(function()
            cb(type(route) == "function" and route(opts) or route or { code = 404, body = "" })
        end)
        return { cancel = function() end }
    end,
    download = function(opts, dest, cb)
        calls[#calls + 1] = opts
        local file = assert(io.open(dest, "wb"))
        file:write(download.body)
        file:close()
        require("ui/uimanager"):nextTick(function() cb(true, nil, { code = download.code }) end)
        return { cancel = function() end }
    end,
}
local function json(data) return { code = 200, body = JSON.encode(data) } end
local function query(opts, key) return opts.url:match("[?&]" .. key .. "=([^&]*)") end

-- 书库：books 行（path）、目录缓存、本地进度。
local books, tocs, stale, progress, remembered, touched, reconciled = {}, {}, {}, {}, {}, {}, nil
local fixed = {}
local dropped = {}
local toc_fresh = true
local shelf_ids, written = {}, {}
package.loaded["book.books_db"] = {
    get = function(_sid, id) return books[id] end,
    getToc = function(_sid, id) return stale[id] end,
    libraryStableIdsBySource = function() return shelf_ids end,
}
package.loaded["book.progress_db"] = {
    get = function(_sid, id) return progress[id] end,
    upsertRemote = function(_sid, id, pos)
        written[id] = pos
        return true
    end,
    fixRemoteTime = function(_sid, id, at)
        fixed[id] = at
        return true
    end,
    dropRemote = function(_sid, id)
        dropped[#dropped + 1] = id
        return true
    end,
}
package.loaded["book.store"] = {
    touch = function(path, ref)
        touched[#touched + 1] = { path = path, stable_id = ref.stable_id }
        books[ref.stable_id] = { path = path }
        return true
    end,
    rememberMany = function(list)
        for _idx, book in ipairs(list) do remembered[book.stable_id] = book end
    end,
}
package.loaded["source.toc"] = {
    read = function(_sid, id) return toc_fresh and tocs[id] or nil end,
    put = function(_sid, id, list)
        tocs[id] = list
        return true
    end,
}
package.loaded["source.shelf"] = {
    reconcile = function(source_id, list, force)
        reconciled = { source_id = source_id, books = list, force = force }
        return { pulled = #list, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    end,
}
local WORK = Config.dir() .. "/kavita_spec"
-- 后台补简介的 done 状态落在沙箱 settings 里：上一轮跑挂留下的状态会让本轮跳过补全。
os.remove(require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua")
os.execute("rm -rf '" .. WORK .. "'")
package.loaded["utils.paths"] = {
    ensureBookWork = function(id) os.execute("mkdir -p '" .. WORK .. "/" .. id .. "'") end,
    bookWorkDir = function(id) return WORK .. "/" .. id end,
}

package.loaded["pluginloader"] = { enabled_plugins = { Config.selfPlugin(), { path = PLUGIN } } }
package.loaded["source.registry"] = nil
local Registry = require("source.registry")

Assert.eq(Registry.meta("ext.kavita").type, "book")
local source = Registry.resolve("ext.kavita")
Assert.is_true(source:configured())
Assert.eq(Registry.external("ext.kavita").setting, require("moonsource_kavita.setting"))
Assert.eq(Registry.external("ext.kavita").home[1], on_deck)

---@return any, any, any
local function run(method, ...)
    local a, b, c
    local n = select("#", ...)
    local args = { ... }
    args[n + 1] = function(x, y, z) a, b, c = x, y, z end
    source[method](source, unpack(args, 1, n + 1))
    Stubs.flush()
    return a, b, c
end

-- 书架：按库分页拉 series，库名即分类；Key 去空白、地址去尾斜杠。
local series_page = {}
for i = 1, 500 do series_page[i] = { id = i, name = "S" .. i, libraryName = "小说", wordCount = i == 1 and 120000 or 0,
    lastChapterAddedUtc = i == 1 and "2026-01-02T03:04:05.123" or nil } end
routes["POST /api/Series/all-v2"] = function(opts)
    local body = JSON.decode(opts.body)
    local lib, page = body.Statements[1].Value, query(opts, "pageNumber")
    if lib == "1" and page == "1" then return json(series_page) end
    if lib == "1" then return json({ { id = 501, name = "S501", libraryName = "小说" } }) end
    return json({ { id = 900, name = "漫画一", libraryName = "漫画", format = 1, pages = 20, pagesRead = 5,
        latestReadDate = "2026-01-02T03:04:05.123" } })
end
local result = run("syncBooksAsync", nil)
Assert.eq(#reconciled.books, 502)
Assert.eq(result.pulled, 503, "对账 502 本 + 1 本漫画进度")
Assert.eq(reconciled.source_id, "ext.kavita")
Assert.eq(reconciled.books[502].category, "漫画")
Assert.eq(reconciled.books[1].stable_id, "1")
Assert.eq(reconciled.books[1].meta.words, 120000, "书架带字数（0 = 未知，入库时丢掉）")
Assert.eq(reconciled.books[1].series, "S1", "系列列填 Kavita series 名，否则图书馆系列页签全是「无系列」")
Assert.eq(reconciled.books[1].inserted_at, 1767323045, "加入时间用 lastChapterAddedUtc，图书馆「最近添加」才跟 Kavita 一致")
Assert.eq(calls[1].headers["x-api-key"], "k")
Assert.matches(calls[1].url, "^http://kav/api/Series/all%-v2%?")
Assert.is_true(run("syncBooksAsync", { dirty_only = true }).skipped, "没有删书接口，只推脏行时跳过")
cfg.libraries = {}
local none, err = run("syncBooksAsync", nil)
Assert.is_nil(none)
Assert.matches(err, "选择书库")
cfg.libraries = { ["1"] = true }

-- 单卷 series：拉目录（标题退到文件名）、写作者简介、下载到 series 行。
routes["GET /api/Series/10"] = json({ id = 10, name = "长夜", libraryId = 1, format = 3 })
routes["GET /api/Series/volumes"] = function(opts)
    local sid = query(opts, "seriesId")
    if sid == "10" then
        return json({ { id = 100, name = "1", chapters = { {
            id = 1000, title = "-100000", titleName = "", format = 3, pages = 12, pagesRead = 0,
            files = { { filePath = "/books/长夜/Long Night.epub" } },
        } } } })
    end
    if sid == "20" then
        return json({
            { id = 200, name = "1", chapters = { { id = 2001, titleName = "第一卷", format = 3, pages = 8, pagesRead = 8 } } },
            { id = 201, name = "2", chapters = { { id = 2002, titleName = "第二卷", format = 3, pages = 10, pagesRead = 0 } } },
        })
    end
    if sid == "30" then
        return json({ { id = 300, chapters = { { id = 3000, titleName = "图册", format = 4, pages = 50 } } } })
    end
    return json({ { id = 400, chapters = { { id = 4000, titleName = "散图", format = 0, pages = 3 } } } })
end
routes["GET /api/Series/metadata"] = json({ summary = "简介", writers = { { name = "甲" }, { name = "乙" } },
    publishers = { { name = "某出版社" } }, releaseYear = 2019, language = "zh" })
for _idx, sid in ipairs({ 20, 30, 40, 50 }) do
    routes["GET /api/Series/" .. sid] = json({ id = sid, name = "合集" .. sid, libraryId = 2 })
end

-- 增量书架：快照指纹没变、本地书架非空就跳过对账；漫画按已读页回填远端进度（本地同页不重写）。
cfg.libraries = { ["2"] = true, ["1"] = true }
Assert.eq(written["900"].page, 5, "首轮同步就回填漫画进度")
Assert.eq(written["900"].fraction, 0.25)
Assert.eq(written["900"].total_pages, 20)
Assert.eq(written["900"].updated_at, 1767323045, "Kavita 时间按 UTC 解析")
reconciled, shelf_ids = nil, { "1" }
progress["900"] = { page = 5 }
result = run("syncBooksAsync", nil)
Assert.is_nil(reconciled, "快照没变不对账")
Assert.eq(result.pulled, 0)
progress["900"] = nil
Assert.eq(run("syncBooksAsync", nil).pulled, 1, "只有漫画进度变了也让书架重绘")
shelf_ids = {}
run("syncBooksAsync", nil)
Assert.is_true(reconciled ~= nil, "本地书架空了（书库被清）照常对账")

-- 对账后后台补简介：只补 intro 为 nil 的行，一本一请求，失败就停。
reconciled = nil
books["1"], books["2"], books["3"] = { intro = "已有" }, {}, {}
local meta_calls = {}
local metadata_route = routes["GET /api/Series/metadata"]
routes["GET /api/Series/metadata"] = function(opts)
    meta_calls[#meta_calls + 1] = query(opts, "seriesId")
    return metadata_route
end
run("syncBooksAsync", { force = true })
Assert.is_true(reconciled ~= nil, "force 不看指纹")
Assert.is_true(reconciled.force, "force 传给对账，书架 meta 覆盖本地")
Assert.eq(table.concat(meta_calls, ","), "2,3")
Assert.eq(remembered["2"].intro, "简介")
Assert.eq(remembered["2"].authors, "甲 / 乙")
Assert.eq(remembered["2"].meta.publisher, "某出版社")
Assert.eq(remembered["2"].meta.published, 2019)
Assert.eq(remembered["2"].meta.language, "zh")
Assert.is_nil(remembered["2"].title, "不碰标题")
-- 书库把空简介存成 NULL：补过的记在单独文件里，否则没简介的书每次同步都重拉。
meta_calls, books["2"], books["3"] = {}, {}, {}
run("syncBooksAsync", { force = true })
Assert.len(meta_calls, 0, "补过的不再补")
local done_file = require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua"
Assert.is_true(require("luasettings"):open(done_file):readSetting("done")["2"])
-- 指纹没变（不对账）也要接着补：换源 / 断网中断过的书不能永远停在未知作者。
meta_calls, remembered["3"] = {}, nil
books["2"], books["3"] = { intro = "已有" }, {}
os.remove(done_file)
Assert.is_true(run("syncBooksAsync", nil).skipped == false, "快照没变也跑完整同步（补简介）")
Assert.eq(table.concat(meta_calls, ","), "3", "没补过的接着补")
Assert.eq(remembered["3"].authors, "甲 / 乙")
os.remove(done_file)
routes["GET /api/Series/metadata"] = function(opts)
    local sid = query(opts, "seriesId")
    meta_calls[#meta_calls + 1] = sid
    -- 只有 2 号失败：后面的 3 号不能被一个坏请求拖住。
    if sid == "2" then return { code = 500, body = "" } end
    return metadata_route
end
meta_calls, remembered["3"], books["2"] = {}, nil, {}
run("syncBooksAsync", { force = true })
Assert.eq(table.concat(meta_calls, ","), "2,3", "单本失败跳过，后面继续补")
Assert.eq(remembered["3"].authors, "甲 / 乙")
online = false
meta_calls = {}
source:backfillMeta({ "2" })
Stubs.flush()
Assert.len(meta_calls, 0, "离线不补")
online = true
routes["GET /api/Series/metadata"] = metadata_route
books["1"], books["2"], books["3"] = nil, nil, nil
cfg.libraries = { ["1"] = true }

local path = run("openBookAsync", { source_id = "ext.kavita", stable_id = "10", book = { title = "长夜" } }, nil)
Assert.eq(path, WORK .. "/10/1000.epub")
Assert.eq(touched[1].stable_id, "10")
Assert.eq(tocs["10"][1].title, "Long Night", "卷名是纯数字、标题是哨兵时退到文件名")
Assert.eq(tocs["10"][1].libraryId, 1)
Assert.eq(remembered["10"].authors, "甲 / 乙")
Assert.eq(remembered["10"].intro, "简介")
Assert.eq(calls[#calls].headers["x-api-key"], "k", "下载带鉴权头")

-- 已下载：直接开，不联网也不重新登记。
online = false
local before = #calls
Assert.eq(run("openBookAsync", { source_id = "ext.kavita", stable_id = "10" }, nil), path)
Assert.eq(#calls, before)
online = true

-- 下载失败：非 2xx 删文件报状态码；2xx 但文件头不对（反代错误页）删文件报校验失败。
download.code, download.body = 500, "<html>oops</html>"
routes["GET /api/Series/11"] = json({ id = 11, name = "坏书", libraryId = 1 })
local saved = routes["GET /api/Series/volumes"]
routes["GET /api/Series/volumes"] = json({ { id = 110, chapters = { { id = 1100, titleName = "坏", format = 3, pages = 1 } } } })
local failed, ferr = run("openBookAsync", { source_id = "ext.kavita", stable_id = "11" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "500")
Assert.is_nil(io.open(WORK .. "/11/1100.epub"))
download.code = 200
tocs["11"] = nil
failed, ferr = run("openBookAsync", { source_id = "ext.kavita", stable_id = "11" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "校验失败")
Assert.is_nil(io.open(WORK .. "/11/1100.epub"))
routes["GET /api/Series/volumes"] = saved
download.body = "PK\3\4epub"

-- 图片目录格式没有可下载的单文件。
failed, ferr = run("openBookAsync", { source_id = "ext.kavita", stable_id = "40" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "图片目录")

-- 离线：没缓存目录就当场失败；有过期目录照用（这里卷已下载，直接开）。
online = false
failed, ferr = run("openBookAsync", { source_id = "ext.kavita", stable_id = "50" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "网络不可用")
online = true

-- 多卷：选卷列表标已读，选中后下到隐藏卷行。
local multi = { source_id = "ext.kavita", stable_id = "20", book = { stable_id = "20", title = "合集", authors = "丙" } }
local opened, oerr
source:openBookAsync(multi, nil, function(p, e) opened, oerr = p, e end)
Stubs.flush()
local list = Themed.last("list")
Assert.len(list.items, 2)
Assert.eq(list.items[1].mandatory, "已读")
Assert.is_nil(list.items[2].mandatory)
Themed.choose(list, 2)
Stubs.flush()
Assert.eq(opened, WORK .. "/20:2002/2002.epub")
Assert.eq(remembered["20:2002"].title, "合集 · 第二卷")
Assert.eq(remembered["20:2002"].series, "合集")
Assert.eq(remembered["20:2002"].authors, "丙", "卷行继承容器作者，最近阅读里不再是未知作者")
Assert.is_nil(remembered["20:2002"].deleted, "卷行不上书架")

-- 关掉选卷列表 = 取消。
source:openBookAsync(multi, nil, function(p, e) opened, oerr = p, e end)
Stubs.flush()
list = Themed.last("list")
Assert.eq(list.items[2].mandatory, "已下载")
list:close()
Stubs.flush()
Assert.matches(oerr, "已取消")

-- 封面：series 与卷各走各的接口，带鉴权头。
local cover = source:coverRequest({ stable_id = "10" })
Assert.eq(cover.url, "http://kav/api/Image/series-cover?seriesId=10")
Assert.eq(cover.headers["x-api-key"], "k")
Assert.eq(source:coverRequest({ stable_id = "20:2002" }).url, "http://kav/api/Image/chapter-cover?chapterId=2002")

-- 拉进度：远端 spine + 锚点 → xpointer；同一 spine 交回本地行；没读过算空。
local volume = { source_id = "ext.kavita", stable_id = "20:2002" }
local remote = { pageNum = 3, bookScrollId = "//body/div[1]/p[5]" }
routes["GET /api/Reader/get-progress"] = function() return json(remote) end
local pos = run("getProgressAsync", volume)
Assert.eq(pos.locator, "/body/DocFragment[4]/body/div/p[5]")
Assert.eq(pos.fraction, 0.3)
Assert.is_nil(pos.page, "epub 不给页码：Kavita 的页是 spine，不是渲染页")
progress["20:2002"] = { locator = "/body/DocFragment[4]/body/p[9]/text().3", fraction = 0.34 }
Assert.eq(run("getProgressAsync", volume), progress["20:2002"])
remote = { pageNum = 0 }
local empty, _e, meta = run("getProgressAsync", volume)
Assert.is_nil(empty)
Assert.is_true(meta.empty)
routes["GET /api/Reader/get-progress"] = { code = 400, body = "" }
_e, _e, meta = run("getProgressAsync", volume)
Assert.is_true(meta.empty)

-- 推进度：spine + 章内路径；读完发 pages。
local sent
routes["POST /api/Reader/progress"] = function(opts)
    sent = JSON.decode(opts.body)
    return { code = 200, body = "" }
end
Assert.is_true(run("putProgressAsync", volume, { fraction = 0.25, locator = "/body/DocFragment[3]/body/div/p[2]/text().0" }))
Assert.eq(sent.pageNum, 2)
Assert.eq(sent.bookScrollId, "//body/div[1]/p[2]")
Assert.eq(sent.chapterId, 2002)
Assert.eq(sent.volumeId, 201)
Assert.eq(sent.libraryId, 2)
Assert.eq(sent.seriesId, 20)
run("putProgressAsync", volume, { fraction = 1, locator = "/body/DocFragment[10]/body/p" })
Assert.eq(sent.pageNum, 10)

-- PDF：按页换算；series 行靠登记的文件名认卷。
local pdf = { source_id = "ext.kavita", stable_id = "30" }
Assert.eq(run("openBookAsync", pdf, nil), nil, "文件头不是 %PDF")
download.body = "%PDF-1.7"
Assert.eq(run("openBookAsync", pdf, nil), WORK .. "/30/3000.pdf")
run("putProgressAsync", pdf, { fraction = 0.2, page = 11, total_pages = 50 })
Assert.eq(sent.pageNum, 10)
Assert.is_nil(sent.bookScrollId)
routes["GET /api/Reader/get-progress"] = function() return json({ pageNum = 20 }) end
pos = run("getProgressAsync", pdf)
Assert.eq(pos.page, 21)
Assert.eq(pos.total_pages, 50)
progress["30"] = { page = 21, fraction = 0.41 }
Assert.eq(run("getProgressAsync", pdf), progress["30"])

-- 离线且目录过期：卷信息退回旧目录，进度照样能推（推送本身由队列等网）。
toc_fresh, online = false, false
stale["20"] = JSON.encode(tocs["20"])
Assert.is_true(run("putProgressAsync", volume, { fraction = 0.5, locator = "/body/DocFragment[6]/body/p" }))
Assert.eq(sent.pageNum, 5)
toc_fresh, online = true, true

-- 注解：没 id 的新建（锚点按本地 epub 段落找，找不到只带 spine），id 原地回填；备注改了才更新。
local epub = {
    ["META-INF/container.xml"] = [[<rootfile full-path="content.opf"/>]],
    ["content.opf"] = [[<manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine>]],
    ["a.xhtml"] = [[<body><p>春眠不觉晓</p></body>]],
}
package.loaded["ffi/archiver"] = { Reader = { new = function()
    return {
        open = function(_self, file) return file == WORK .. "/20:2002/2002.epub" end,
        iterate = function() return function() end end,
        extractToMemory = function(_self, name) return epub[name] end,
        close = function() end,
    }
end } }
local created, updated = {}, {}
routes["POST /api/Annotation/create"] = function(opts)
    created[#created + 1] = JSON.decode(opts.body)
    return json({ id = 70 + #created })
end
routes["POST /api/Annotation/update"] = function(opts)
    updated[#updated + 1] = JSON.decode(opts.body)
    return json({})
end
local anns = {
    { drawer = "lighten", text = "春眠\n不觉晓", note = "好诗", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" },
    { drawer = "underscore", text = "𠀀找不到", pos0 = "/body/DocFragment[3]/body/p/text().0" },
    { text = "书签", pos0 = "/body/DocFragment[1]/body/p" },
}
Assert.is_true(run("pushNotesAsync", volume, anns))
Assert.len(created, 2, "书签不推")
Assert.eq(created[1].xPath, "//body/p[1]")
Assert.eq(created[1].endingXPath, "//body/p[1]")
Assert.eq(created[1].pageNumber, 0)
Assert.eq(created[1].comment, "好诗")
Assert.eq(created[1].selectedText, "春眠\n不觉晓")
Assert.eq(created[1].highlightCount, 6, "按 UTF-16 码元计")
Assert.eq(created[1].chapterId, 2002)
Assert.eq(created[1].volumeId, 201)
Assert.eq(created[1].libraryId, 2)
Assert.eq(created[1].seriesId, 20)
Assert.eq(created[2].xPath, "")
Assert.eq(created[2].pageNumber, 2, "找不到段落只带 spine")
Assert.eq(created[2].highlightCount, 5, "扩展区汉字占两个码元")
Assert.eq(anns[1].kavita_id, 71)
Assert.eq(anns[2].kavita_id, 72)
created = {}
Assert.is_true(run("pushNotesAsync", volume, anns))
Assert.len(created, 0, "推过的不重建")
Assert.len(updated, 0)
anns[1].note = "改了"
Assert.is_true(run("pushNotesAsync", volume, anns))
Assert.eq(updated[1].id, 71)
Assert.eq(updated[1].comment, "改了")
Assert.eq(anns[1].kavita_note, "改了")

-- 全部失败才报错（核心留脏重试）；有一条成功就要回填落库，免得重试时重复建。
routes["POST /api/Annotation/create"] = { code = 500, body = "" }
anns[3].drawer = "lighten"
local okn, nerr = run("pushNotesAsync", volume, anns)
Assert.is_nil(okn)
Assert.matches(nerr, "500")
anns[1].note = "再改"
Assert.is_true(run("pushNotesAsync", volume, anns))
Assert.is_nil(anns[3].kavita_id)

-- 非 epub 不推。
Assert.is_true(run("pushNotesAsync", pdf, { { drawer = "lighten", text = "图", pos0 = "x" } }))

-- 快照：清洗保留 Kavita id，保存时按 pos0 从上一版接过 id。
local clean = source:cleanAnnotations({
    { datetime = "d", page = 1, drawer = "lighten", text = "x", pos0 = "p", kavita_id = 71, kavita_note = "n", junk = 1 },
    { text = "没有时间的丢掉" },
}, 10)
Assert.len(clean, 1)
Assert.eq(clean[1].kavita_id, 71)
Assert.eq(clean[1].kavita_note, "n")
Assert.eq(clean[1].total_pages, 10)
Assert.is_nil(clean[1].junk)
local current = source:prepareLocalAnnotations(
    { { pos0 = "p", kavita_id = 71, kavita_note = "n" }, { pos0 = "gone", kavita_id = 9 } },
    { { pos0 = "p", note = "新" }, { pos0 = "q" } })
Assert.eq(current[1].kavita_id, 71)
Assert.eq(current[1].kavita_note, "n", "备注差异留给推送时比对")
Assert.is_nil(current[2].kavita_id)

-- 详情：卷行取所属 series 的 metadata，写回这一行。
routes["GET /api/Series/metadata"] = function(opts)
    Assert.eq(query(opts, "seriesId"), "20")
    return json({ summary = "卷简介", writers = { { name = "丁" } } })
end
local detail = run("getDetailAsync", { source_id = "ext.kavita", stable_id = "20:2002" })
Assert.eq(detail.intro, "卷简介")
Assert.eq(remembered["20:2002"].authors, "丁")

-- kamare：漫画在线看（从 Kavita 记录的下一页起），回调 handled 不开阅读器；
-- 关查看器记本地进度；章末续读下一卷；打不开时 cbz 退回下载。
routes["GET /api/Series/metadata"] = metadata_route
local viewers, stream_ok = {}, true
package.loaded["kamareimageviewer"] = { new = function(_self, spec)
    viewers[#viewers + 1] = spec
    return spec
end }
package.loaded["kavitaclient"] = { streamChapter = function(_self, id) return stream_ok and { id } or nil end }
routes["GET /api/Series/60"] = json({ id = 60, name = "漫画", libraryId = 3 })
local volumes_route = routes["GET /api/Series/volumes"]
routes["GET /api/Series/volumes"] = function(opts)
    if query(opts, "seriesId") ~= "60" then return volumes_route(opts) end
    return json({
        { id = 600, chapters = { { id = 6000, titleName = "第1话", format = 1, pages = 30 } } },
        { id = 601, chapters = { { id = 6001, titleName = "第2话", format = 1, pages = 20 } } },
    })
end
routes["GET /api/Reader/get-progress"] = function(opts)
    return json({ pageNum = query(opts, "chapterId") == "6001" and 4 or 0 })
end
local comic = { source_id = "ext.kavita", stable_id = "60", book = { stable_id = "60", title = "漫画" } }
local cpath, cerr, cmeta
source:openBookAsync(comic, nil, function(p, e, m) cpath, cerr, cmeta = p, e, m end)
Stubs.flush()
Themed.choose(Themed.last("list"), 2)
Stubs.flush()
Assert.is_nil(cpath)
Assert.is_nil(cerr)
Assert.is_true(cmeta.handled)
Assert.eq(viewers[1].metadata.chapterId, 6001)
Assert.eq(viewers[1].metadata.startPage, 5)
Assert.eq(viewers[1].images_list_nb, 20)
Assert.eq(viewers[1].title, "漫画")
Assert.eq(require("kavitaclient").api_key, "k")
viewers[1].on_close_callback(10, 20)
Assert.eq(written["60:6001"].page, 10)
Assert.eq(written["60:6001"].fraction, 0.5)
viewers[1].on_next_chapter_callback(6000)
Stubs.flush()
Assert.eq(viewers[2].metadata.chapterId, 6000)
Assert.eq(viewers[2].metadata.startPage, 1)

stream_ok, download.body = false, "PK\3\4cbz"
source:openBookAsync(comic, nil, function(p, e, m) cpath, cerr, cmeta = p, e, m end)
Stubs.flush()
Themed.choose(Themed.last("list"), 1)
Stubs.flush()
Assert.eq(cpath, WORK .. "/60:6000/6000.cbz", "kamare 打不开，cbz 退回下载")
Assert.is_nil(cmeta)
Assert.len(viewers, 2)
stream_ok = true
Assert.eq(run("openBookAsync", { source_id = "ext.kavita", stable_id = "60:6000" }, nil), cpath,
    "下载过的直接开，不再走 kamare")
Assert.len(viewers, 2)
os.remove(require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua")

-- 服务端已读回填：网页端 / 别的设备读过的 epub 也要进「最近阅读」并可能标已读。
-- series 级 pagesRead/pages 对 epub 只是 spine 比例，只补本地没有进度的书，绝不覆盖精确位置。
local shelf_route = routes["POST /api/Series/all-v2"]
local read_route = json({
    { id = 700, name = "读过一半", libraryName = "书籍", format = 3, pages = 200, pagesRead = 50,
      -- Kavita 同时给本地与 UTC 两个口径：差值 = 服务器时区（这里 UTC+8）。
      lastChapterAdded = "2026-02-03T11:05:06.1", lastChapterAddedUtc = "2026-02-03T03:05:06.1",
      latestReadDate = "2026-02-03T04:05:06.123" },
    { id = 701, name = "读完了", libraryName = "书籍", format = 3, pages = 10, pagesRead = 10,
      lastChapterAdded = "2026-02-03T11:05:06.1", lastChapterAddedUtc = "2026-02-03T03:05:06.1",
      latestReadDate = "2026-02-03T04:05:06.123" },
    { id = 710, name = "多卷书", libraryName = "书籍", format = 3, pages = 300, pagesRead = 90,
      lastChapterAdded = "2026-02-03T11:05:06.1", lastChapterAddedUtc = "2026-02-03T03:05:06.1",
      latestReadDate = "2026-02-03T04:05:06.123" },
})
-- 多卷 series：卷行上已经有进度 → 不再往容器行回填（否则最近阅读会多一条没阅读位置的重复条目），
-- 早先回填过的容器占位行也要清掉。
tocs["710"] = { { chapterId = 7101, title = "上" }, { chapterId = 7102, title = "下" } }
progress["710:7101"] = { fraction = 0.3, updated_at = os.time() - 3600 }
progress["710"] = { fraction = 0.5, updated_at = os.time() - 3600 }
books["710"] = { title = "多卷书", authors = "甲", intro = "简介", category = "书籍" }
routes["POST /api/Series/all-v2"] = read_route
written = {}
run("syncBooksAsync", { force = true })
Assert.eq(written["700"].fraction, 0.25)
Assert.is_nil(written["700"].page, "epub 不写页码：Kavita 的页是 spine")
-- latestReadDate 是服务器本地时间（04:05 CST = 20:05Z 前一天），不是 UTC；
-- 按 UTC 解析会存成 1770091506（8 小时后的未来），刚读完的书就会被它压在下面。
Assert.eq(written["700"].updated_at, 1770062706, "latestReadDate 按服务器时区换成真 epoch")
Assert.eq(written["701"].fraction, 1, "读完的写满比例，进步进「已读」")
Assert.is_nil(written["710"], "按卷读的书不再往容器行回填，避免重复条目")
Assert.eq(remembered["710:7101"].authors, "甲", "读过的卷行继承容器作者，不再显示未知作者")
Assert.eq(remembered["710:7101"].title, "多卷书 · 上")
Assert.eq(remembered["710:7101"].category, "书籍")
dropped = {}
run("syncBooksAsync", { force = true })
Assert.eq(dropped[1], "710", "容器行残留的占位进度被清掉")
written = {}
progress["700"] = { fraction = 0.4 }
run("syncBooksAsync", { force = true })
Assert.is_nil(written["700"], "本地有进度就不回填，不覆盖精确位置")

-- 旧版已经写进库的未来时间：同步时拉回真实时间（只降不升）。
written, fixed = {}, {}
progress["700"] = { fraction = 0.4, updated_at = os.time() + 8 * 3600 }
run("syncBooksAsync", { force = true })
Assert.eq(fixed["700"], 1770062706, "库里的未来时间被拉回 Kavita 的真实阅读时间")
progress["700"] = nil
routes["POST /api/Series/all-v2"] = shelf_route

os.execute("rm -rf '" .. WORK .. "'")
