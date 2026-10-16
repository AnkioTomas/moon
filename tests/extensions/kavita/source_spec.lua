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
for _idx, name in ipairs({ "client", "position", "source", "setting", "kamare", "stats" }) do
    package.preload["moonsource_kavita." .. name] = function()
        return dofile(PLUGIN .. "/moonsource_kavita/" .. name .. ".lua")
    end
end
-- 首页组件另有 on_deck_spec；这里只验证描述表把它交出去。
local on_deck = { id = "ext.kavita.on_deck" }
package.preload["moonsource_kavita.on_deck"] = function() return on_deck end

local cfg = { base_url = "http://kav/", api_key = " k ", libraries = { ["2"] = true, ["1"] = true } }
local clock = { timezone = "CST-8" }
package.preload["utils.settings"] = function()
    local common = { active_source = "local" }
    return {
        get = function(key) return key == "features.clock" and clock or common end,
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
local routes, calls, held = {}, {}, {}
local download = { code = 200, body = "PK\3\4epub" }
package.loaded["http.request"] = {
    ok = function(code)
        code = tonumber(code)
        return code ~= nil and code >= 200 and code < 300
    end,
    -- 与真 Request.header 同语义（大小写不敏感；测试里响应头是普通表）。
    header = function(res, name)
        for key, value in pairs(res and res.headers or {}) do
            if type(key) == "string" and key:lower() == name:lower() then return value end
        end
    end,
    request = function(opts, cb)
        calls[#calls + 1] = opts
        local route = routes[opts.method .. " " .. opts.url:match("^http://kav(/[^?]*)")]
        require("ui/uimanager"):nextTick(function()
            local response = type(route) == "function" and route(opts) or route or { code = 404, body = "" }
            -- { hold = true, reply = … }：把回包压住，测试用 held 自行放出（验证取消 / 在途中止）。
            if type(response) == "table" and response.hold then
                held[#held + 1] = function() cb(response.reply) end
                return
            end
            cb(response)
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
local function json(data, headers) return { code = 200, body = JSON.encode(data), headers = headers } end
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
-- 统计状态（上次身份 + 系列章数）同理：留着会让本轮读不到「首次拉取」的行为。
-- .old 备份一起去掉：主文件被删时 LuaSettings 会回落它（别的 spec 中断留下的档就活过来了）。
local STATS_STATE = require("datastorage"):getSettingsDir() .. "/moonsource_kavita_stats.lua"
for _idx, suffix in ipairs({ "", ".old" }) do os.remove(STATS_STATE .. suffix) end
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
Assert.eq(require("moonsource_kavita.source").DEFAULT_HEARTBEAT_INTERVAL, 30, "设置页读的默认心跳间隔")

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
Assert.eq(calls[1].timeout, 60, "拉书架带足够长的超时，慢设备不会一拉就 30s 超时")
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

-- 容器行的作者是 fetchToc 在这次开书里才写回的，identity.book 是开书那一刻的旧快照：
-- 选卷要用重读后的容器行，否则新 series 第一次打开写下的卷行又是「未知作者」。
books["21"] = { stable_id = "21", title = "合集21", authors = "丁" }
routes["GET /api/Series/21"] = json({ id = 21, name = "合集21", libraryId = 2 })
local volumes_route = routes["GET /api/Series/volumes"]
routes["GET /api/Series/volumes"] = function(opts)
    if query(opts, "seriesId") == "21" then
        return json({
            { id = 210, name = "1", chapters = { { id = 2101, titleName = "上", format = 3, pages = 5 } } },
            { id = 211, name = "2", chapters = { { id = 2102, titleName = "下", format = 3, pages = 5 } } },
        })
    end
    return volumes_route(opts)
end
source:openBookAsync(
    { source_id = "ext.kavita", stable_id = "21", book = { stable_id = "21", title = "合集21" } },
    nil, function() end)
Stubs.flush()
Themed.choose(Themed.last("list"), 1)
Stubs.flush()
Assert.eq(remembered["21:2101"].authors, "丁", "卷行取重读后的容器行，不用开书时的旧快照")
routes["GET /api/Series/volumes"] = volumes_route
books["21"] = nil

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

-- 拉进度：远端 spine + 锚点 → xpointer；没读过算空。
local volume = { source_id = "ext.kavita", stable_id = "20:2002" }
local remote = { pageNum = 3, bookScrollId = "//body/div[1]/p[5]" }
routes["GET /api/Reader/get-progress"] = function() return json(remote) end
local pos, _err, meta = run("getProgressAsync", volume)
Assert.eq(pos.locator, "/body/DocFragment[4]/body/div/p[5]")
Assert.eq(pos.fraction, 0.3)
Assert.is_nil(pos.page, "epub 不给页码：Kavita 的页是 spine，不是渲染页")
Assert.is_true(meta and meta.page_level == true, "页级源必须声明 page_level：core 才不按百分比判")
Assert.is_nil(_err)
-- 同一 spine：锚点与本机上次同步的位置不同（网页端在同一条里往后读了几页）→ 用远端坐标，
-- 不能返回本地行——否则 core 的 synced 基线永远看不到「云端动过」。
progress["20:2002"] = {
    locator = "/body/DocFragment[4]/body/p[9]/text().3",
    fraction = 0.34,
    synced = { locator = "/body/DocFragment[4]/body/p[3]/text().0" },
}
local moved = run("getProgressAsync", volume)
Assert.eq(moved.locator, "/body/DocFragment[4]/body/div/p[5]", "同 spine 锚点变了就要跟远端")
Assert.eq(moved.fraction, 0.3)
-- 同一 spine 且锚点就是上次同步的位置 → 交回本地行（粒度噪声不当冲突，也不跳）
progress["20:2002"].synced = { locator = "/body/DocFragment[4]/body/div[1]/p[5]" }
Assert.eq(run("getProgressAsync", volume), progress["20:2002"])
-- 同一 spine 但远端只有 spine 粒度（没带锚点 / 锚点解不出）→ 交回本地行，不把人拽回节首。
routes["GET /api/Reader/get-progress"] = function() return json({ pageNum = 3 }) end
Assert.eq(run("getProgressAsync", volume), progress["20:2002"])
-- 旧行没有基线（synced 为空）→ 保守交回本地行，不拿不可比的粒度去判
routes["GET /api/Reader/get-progress"] = function() return json(remote) end
progress["20:2002"].synced = nil
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
local vol_result = run("syncBooksAsync", { force = true })
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
-- 对齐必须算进同步变更：pulled 全 0 时桌面不发 shelf_changed，首页「当前阅读」不重画，
-- 卡片会一直停在未知作者（对账 3 本 + 回填 700/701 各 1 + 卷行对齐 1 + 清容器占位 1）。
Assert.eq(vol_result.pulled, 7, "卷行元数据对齐算一次变更，首页才会重画")
-- 卷行按真实书库落库后（rememberMany 会写库），重复同步不再是变更，否则每次同步都白刷首页。
books["710:7101"] = remembered["710:7101"]
local vol_again = run("syncBooksAsync", { force = true })
Assert.eq(vol_result.pulled - vol_again.pulled, 1, "已对齐的卷行不再重复计入变更")
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

-- 阅读期进度心跳：Kavita 的阅读会话时长按相邻两次进度写入的间隔算，只在关书推一次，
-- Kavita 那边就是一个 StartTime == EndTime 的 0 秒会话。翻页 / 切章 / 唤醒起心跳：位置一变
-- 就补推（节流合并密集翻页），另有兜底定时拍照顾慢读；离线或上一拍未回就跳过这一拍；
-- 关书 / 休眠 / 关源即停。
do
    local UIManager = require("ui/uimanager")
    local real_in, real_un, real_time = UIManager.scheduleIn, UIManager.unschedule, os.time
    local scheduled = {}
    UIManager.scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end
    UIManager.unschedule = function(_self, fn)
        for i = #scheduled, 1, -1 do
            if scheduled[i].fn == fn then table.remove(scheduled, i) end
        end
    end
    local now = 1800000000
    os.time = function(t) return t and real_time(t) or now end
    local function advance(seconds) now = now + seconds end
    local function fire() table.remove(scheduled, 1).fn(); Stubs.flush() end

    sent = nil
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.4, locator = "/body/DocFragment[5]/body/div/p[1]/text().0" },
    })
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.5, locator = "/body/DocFragment[6]/body/div/p[2]/text().0" },
    })
    Assert.len(scheduled, 1, "同一本书只有一个心跳")
    Assert.eq(scheduled[1].delay, 30, "拍间隔就是设置的心跳间隔（默认 30 秒）")
    Assert.is_nil(sent, "起心跳不当场发请求（避开开书拉取）")

    -- 位置一变就补推：Kavita 认的是两次写入之间的跨度，必须真的把新位置写上去。
    advance(31)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.55, locator = "/body/DocFragment[6]/body/div/p[3]/text().0" },
    })
    Stubs.flush()
    Assert.eq(sent.pageNum, 5, "翻页后推新位置（spine）")
    Assert.eq(sent.bookScrollId, "//body/div[1]/p[3]")
    Assert.len(scheduled, 1, "补推不另起定时器")

    -- 距上次不足 MIN_PUSH_GAP 的翻页：合并，交给下一拍，不每页一发。
    sent = nil
    advance(10)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.6, locator = "/body/DocFragment[7]/body/p[1]/text().0" },
    })
    Assert.is_nil(sent, "翻页密集时合并")

    -- 兜底定时拍到点：推最近一次的位置。
    advance(120)
    fire()
    Assert.eq(sent.pageNum, 6, "定时拍推最近位置")
    Assert.len(scheduled, 1, "一拍结束后重排下一拍")

    -- 位置没变的兜底拍：跳过，别白推（Kavita 对同位置也会 early-return）。
    sent = nil
    advance(200)
    fire()
    Assert.is_nil(sent, "位置没变不推")
    Assert.len(scheduled, 1)

    -- 离线只跳过这一拍，不补报，但心跳继续（重排已经发生）。
    online, sent = false, nil
    advance(200)
    fire()
    Assert.is_nil(sent, "离线不发")
    Assert.len(scheduled, 1)
    online = true

    -- 上一拍回包还没落地：busy 未清，本拍跳过，不重复发也不丢位置。
    local before = #calls
    advance(61)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.7, locator = "/body/DocFragment[8]/body/p[1]/text().0" },
    })
    Assert.is_true(source._heartbeat.busy, "第一拍在飞")
    sent = nil
    advance(61)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.8, locator = "/body/DocFragment[9]/body/p[1]/text().0" },
    })
    Stubs.flush()
    Assert.eq(#calls, before + 1, "上一拍未回，本拍不发")
    Assert.eq(sent.pageNum, 7, "推的是飞出去那一拍的位置")
    Assert.is_true(not source._heartbeat.busy, "回包落地后 busy 复位")

    -- 换书：停旧心跳，为新书重排。
    local other = { source_id = "ext.kavita", stable_id = "20:2001" }
    source:onEvent("page_changed", { identity = other, position = { fraction = 0.1 } })
    Assert.len(scheduled, 1, "换书只留一个心跳")
    Assert.eq(source._heartbeat.identity.stable_id, "20:2001")

    -- 关书 / 休眠停掉，不再有调度。
    source:onEvent("reading_stopped", { identity = other })
    Assert.len(scheduled, 0, "关书 / 休眠停心跳")
    Assert.is_nil(source._heartbeat)

    -- 关源也要停（换源时旧实例可能还挂着）。
    source:onEvent("chapter_changed", { identity = volume, position = { fraction = 0.2 } })
    Assert.len(scheduled, 1)
    source:close()
    Assert.len(scheduled, 0, "关源停心跳")

    -- 心跳间隔可配置：调大后按新间隔节流，兜底拍跟着放大；0 = 关闭阅读期心跳。
    cfg.heartbeat_interval = 120
    source:onEvent("page_changed", { identity = volume, position = { fraction = 0.9 } })
    Assert.len(scheduled, 1, "改间隔后起心跳")
    Assert.eq(scheduled[1].delay, 120, "兜底拍跟到新间隔，不白醒")
    sent = nil
    advance(31)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.91, locator = "/body/DocFragment[6]/body/p[9]/text().0" },
    })
    Stubs.flush()
    Assert.is_nil(sent, "120s 间隔内不推")
    advance(100)
    source:onEvent("page_changed", {
        identity = volume,
        position = { fraction = 0.92, locator = "/body/DocFragment[6]/body/p[10]/text().0" },
    })
    Stubs.flush()
    Assert.is_true(sent ~= nil, "超过 120s 后补推")

    cfg.heartbeat_interval = 0
    source:onEvent("page_changed", { identity = volume, position = { fraction = 0.93 } })
    Assert.len(scheduled, 0, "0 = 关闭心跳，不再调度")
    Assert.is_nil(source._heartbeat)
    cfg.heartbeat_interval = nil

    UIManager.scheduleIn, UIManager.unschedule, os.time = real_in, real_un, real_time
end

-- 统计钩子：能力申报 + 推送 = 纯本地确认。Kavita 侧的阅读历史由服务端自己记录（会话 × 系列，
-- 带章节明细），本机没有对应的上报接口；确认后这些行不再是脏行，展示仍按
-- 「云端快照 + 拉取后本地新读」合并。
do
    local SourceCapabilities = require("source.base").SourceCapabilities
    Assert.is_true(source:capabilities().stats_pull, "申报可拉取统计")
    Assert.is_true(SourceCapabilities.supportsStatsPull(source), "框架入口据此调 pullStatsAsync")

    local confirmed, returned
    local before_calls = #calls
    returned = source:pushStatsAsync({ { id = 7 }, { id = 8 } }, function(data) confirmed = data end)
    Assert.is_nil(confirmed, "当场能回的结果也下一帧回调（源契约：defer，cancel 句柄先于回调成立）")
    Assert.not_nil(returned and returned.cancel, "返回可取消句柄（在飞取消是契约的一部分）")
    Stubs.flush()
    Assert.eq(confirmed.synced_ids[1], 7, "确认回本批行 id（框架据此标 sync_status=1）")
    Assert.eq(confirmed.synced_ids[2], 8)
    Assert.eq(#calls, before_calls, "本地确认不发请求")
    confirmed = nil
    source:pushStatsAsync(nil, function(data) confirmed = data end)
    Stubs.flush()
    Assert.eq(#confirmed.synced_ids, 0, "空批次也回空表，不报错")

    -- 取消：下一帧之前取消，回调不再到达。
    local reached = false
    returned = source:pushStatsAsync({ { id = 9 } }, function() reached = true end)
    returned:cancel()
    Stubs.flush()
    Assert.is_false(reached, "取消后不回调")
end

-- 拉取全量阅读历史：按分页头展开两页；参数形态（Libraries 重复键 / TimeZoneId / PageSize=200 /
-- 不带日期范围）；身份判定命中目录缓存（4 章 = 多卷 → 逐卷身份）；替换指令与核心对账基线一致。
local warnings = {}
do
    local log = require("utils.log")
    log.warn = function(...) warnings[#warnings + 1] = table.concat({ ... }, " ") end
end
--- 记录某次拉取里出现过「跳过系列」的警告（按 seriesId 找）。
local function warnedAbout(series_id)
    for _idx, text in ipairs(warnings) do
        if text:find(series_id, 1, true) then return true end
    end
    return false
end
local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end
local history = dofile(Config.root() .. "/tests/extensions/kavita/fixtures/history_7453.lua")
local history_pages = { {}, {} }
for _idx, entry in ipairs(history) do
    local page = #history_pages[1] < 50 and 1 or 2
    history_pages[page][#history_pages[page] + 1] = entry
end
local history_calls = {}
--- 分页头与响应体同一套往返桩：client 读到的就是「JSON 串 → 表」这条路。
local function pagination_header(page, pages)
    return JSON.encode({ currentPage = page, itemsPerPage = 50, totalItems = 64, totalPages = pages })
end
routes["GET /api/Stats/reading-history"] = function(opts)
    local page = tonumber(query(opts, "PageNumber"))
    history_calls[#history_calls + 1] = opts.url
    return json(history_pages[page], { Pagination = pagination_header(page, 2) })
end
tocs["7453"] = { { chapterId = 11270 }, { chapterId = 11271 }, { chapterId = 11272 }, { chapterId = 11273 } }
-- 未选书库：与书架同步同类的配置错误，零请求（配置好了自然会重拉）。
cfg.libraries = {}
local nolibs_before = #calls
local nolibs, nolibs_err = run("pullStatsAsync")
Assert.is_nil(nolibs)
Assert.matches(nolibs_err, "选择书库")
Assert.eq(#calls, nolibs_before, "未配置不发请求")
cfg.libraries = { ["2"] = true, ["1"] = true }
local pulled = run("pullStatsAsync")
Assert.len(history_calls, 2, "分页头说两页就拉两页")
Assert.matches(history_calls[1], "Libraries=1&Libraries=2", "库集合是重复键")
Assert.matches(history_calls[1], "TimeZoneId=Asia%%2FShanghai", "设备时钟 POSIX → IANA")
Assert.matches(history_calls[1], "PageSize=200")
Assert.matches(history_calls[1], "PageNumber=1&", "从第 1 页开始")
Assert.is_nil(history_calls[1]:match("StartDate"), "全量重拉不带日期范围")
Assert.matches(history_calls[2], "PageNumber=2&")
local pulled_total
for _idx, row in ipairs(pulled.rows) do
    if row.record_type == "total" then pulled_total = row end
end
Assert.eq(pulled_total.duration, 14237, "两页合并后与样本书基线一致")
Assert.eq(pulled_total.source_id, "ext.kavita")
Assert.eq(pulled.replace.mode, "ranges")
Assert.len(pulled.replace.books, 2, "本次身份（7453 的 4 章里读过两卷）")
Assert.contains(pulled.replace.books, "7453:11273")
Assert.not_nil(pulled.commit, "落库成功后由核心回调 commit")
Assert.len(history_calls, 2, "目录命中缓存，不为身份判定多请求")

-- 设备时钟的 POSIX 串映射不出 IANA 时区（自定义 / 未知）时回退 UTC：服务端只认 IANA，
-- 宁可与设备差一天，不静默用错时区。
clock.timezone = "NOPE-1"
history_calls = {}
Assert.not_nil(run("pullStatsAsync"))
Assert.matches(history_calls[1], "TimeZoneId=UTC", "无法识别的时区回退 UTC")
clock.timezone = "CST-8"

-- 身份判定：目录缓存里没有的系列走 Source:toc（在线拉目录）后逐卷记；目录拿不到的系列整条跳过
-- （不猜单卷 / 多卷），不中断其它系列。判定结果随 commit 记进状态文件，下一轮不再请求目录。
do
    local stats_history = {
        { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 600, pagesRead = 3 } } },
        { seriesId = 10560, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 16493, durationSeconds = 300, pagesRead = 0 } } },
        { seriesId = 999, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 5, durationSeconds = 111, pagesRead = 0 } } },
    }
    routes["GET /api/Stats/reading-history"] = function()
        return json(stats_history, { Pagination = pagination_header(1, 1) })
    end
    local volumes_route = routes["GET /api/Series/volumes"]
    routes["GET /api/Series/8661"] = json({ id = 8661, name = "人类简史", libraryId = 1 })
    routes["GET /api/Series/10560"] = json({ id = 10560, name = "镖人", libraryId = 1 })
    routes["GET /api/Series/999"] = { code = 404, body = "" }
    routes["GET /api/Series/volumes"] = function(opts)
        if query(opts, "seriesId") == "8661" then
            return json({ { id = 86610, chapters = { { id = 12763, titleName = "全", format = 3, pages = 10 } } } })
        end
        if query(opts, "seriesId") == "10560" then
            return json({
                { id = 105600, chapters = { { id = 16493, titleName = "一", format = 1, pages = 20 } } },
                { id = 105601, chapters = { { id = 16494, titleName = "二", format = 1, pages = 20 } } },
                { id = 105602, chapters = { { id = 16495, titleName = "三", format = 1, pages = 20 } } },
            })
        end
        return volumes_route(opts)
    end
    tocs["8661"] = { { chapterId = 12763 } }

    local before = #calls
    local pulled = run("pullStatsAsync")
    local day = os.time({ year = 2026, month = 10, day = 10, hour = 0 })
    local function findBook(rows, record_type, stable_id)
        for _idx, row in ipairs(rows) do
            if row.record_type == record_type and row.stable_id == stable_id then return row end
        end
    end
    Assert.eq(findBook(pulled.rows, "book_day", "8661", day).duration, 600, "1 章 = 单卷，读在 series 行")
    Assert.eq(findBook(pulled.rows, "book_day", "10560:16493", day).duration, 300, "3 章 = 多卷，读在卷行")
    Assert.eq(findBook(pulled.rows, "total", "__kv:total").duration, 900, "判不出身份的系列不进总量")
    for _idx, row in ipairs(pulled.rows) do
        Assert.is_nil(row.stable_id:match("^999"), "目录拿不到的系列不猜身份")
    end
    local series_calls = {}
    for idx = before + 1, #calls do
        local sid = calls[idx].url:match("^http://kav/api/Series/(%d+)$")
        if sid then series_calls[#series_calls + 1] = sid end
    end
    Assert.eq(table.concat(series_calls, ","), "10560,999", "缓存里有 8661，只判 10560 与 999")
    Assert.is_true(warnedAbout("999"), "跳过的系列要能被日志定位")

    pulled.commit()
    local state = require("luasettings"):open(STATS_STATE)
    Assert.eq(state:readSetting("volumes")["8661"], 1, "单卷判定入状态文件")
    Assert.eq(state:readSetting("volumes")["10560"], 3, "多卷判定入状态文件")
    Assert.is_nil(state:readSetting("volumes")["999"], "判不出的系列不落状态，下轮还会再试")
    local identities = state:readSetting("identities")
    Assert.len(identities, 2)
    Assert.contains(identities, "8661")
    Assert.contains(identities, "10560:16493")

    -- 第二轮：目录缓存清空（再走判定就得发请求），但状态文件里有章数 → 一行请求都不发。
    tocs["8661"], tocs["10560"] = nil, nil
    routes["GET /api/Series/10560"] = { code = 404, body = "" }
    routes["GET /api/Series/volumes"] = function() return { code = 404, body = "" } end
    before = #calls
    local again = run("pullStatsAsync")
    Assert.eq(findBook(again.rows, "book_day", "8661", day).duration, 600, "身份判定走状态文件，结果不变")
    Assert.eq(findBook(again.rows, "book_day", "10560:16493", day).duration, 300)
    series_calls = {}
    for idx = before + 1, #calls do
        local sid = calls[idx].url:match("^http://kav/api/Series/(%d+)$")
        if sid then series_calls[#series_calls + 1] = sid end
    end
    Assert.eq(table.concat(series_calls, ","), "999", "已判定的系列不再请求目录")
    Assert.len(again.replace.books, 2, "上次身份 ∪ 本次身份，旧身份的孤儿行照样清")
    again.commit()
    routes["GET /api/Series/volumes"] = volumes_route
end

-- 缺行卷物化：云端读过、本机没有书行的卷（seriesId:chapterId）补一条轻量身份行 —— 标题
-- 「系列 · 卷名」、继承容器行的作者 / 简介 / 分类 / 系列，不写封面。洞察「当日书单」、单书详情、
-- 锁屏账单才有书名而不是裸 ID。隐藏身份行（库里落成 deleted=1 + sync_status=1）不上架、
-- 不触发书架对账、不进书架同步结果，写库只由本次统计同步的 stats_changed 带走；
-- 容器行缺失时跳过物化（统计行照写）。
do
    local day = os.time({ year = 2026, month = 10, day = 10, hour = 0 })
    local function findRow(rows, record_type, stable_id)
        for _idx, row in ipairs(rows) do
            if row.record_type == record_type and row.stable_id == stable_id then return row end
        end
    end
    routes["GET /api/Stats/reading-history"] = function()
        return json({
            { seriesId = 8801, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 88010, durationSeconds = 600, pagesRead = 1 } } },
            { seriesId = 8802, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 88020, durationSeconds = 300, pagesRead = 0 } } },
            { seriesId = 8803, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 88030, durationSeconds = 120, pagesRead = 0 } } },
            { seriesId = 8804, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 88040, durationSeconds = 60, pagesRead = 0 } } },
        }, { Pagination = pagination_header(1, 1) })
    end
    tocs["8801"] = { { chapterId = 88010, title = "第二卷" }, { chapterId = 88011, title = "第三卷" } }
    tocs["8802"] = { { chapterId = 88020, title = "上" }, { chapterId = 88021, title = "下" } }
    tocs["8803"] = { { chapterId = 88030, title = "全" } }
    -- 卷名拿不到的老目录（只剩 chapterId）：物化标题的卷名退容器名，不留裸 ID / 空标题。
    tocs["8804"] = { { chapterId = 88040 }, { chapterId = 88041 } }
    books["8801"] = { title = "合集", authors = "甲", intro = "简介", category = "书籍" }
    books["8803"] = { title = "单卷书", authors = "乙", category = "书籍" }
    books["8804"] = { title = "太空漫游", authors = "丙", category = "书籍" }

    reconciled, remembered = nil, {}
    local pulled = run("pullStatsAsync")
    local material = remembered["8801:88010"]
    Assert.eq(material and material.title, "合集 · 第二卷", "标题 = 系列 · 卷名（卷名取目录条目）")
    Assert.eq(material and material.authors, "甲", "作者继承容器行")
    Assert.eq(material and material.intro, "简介", "简介继承容器行")
    Assert.eq(material and material.category, "书籍", "分类继承容器行")
    Assert.eq(material and material.series, "合集", "系列列继承容器行")
    Assert.is_nil(material and material.cover, "封面不写：卷封面走源既有取图链路")
    Assert.is_nil(material and material.path, "不是下载行")
    Assert.is_nil(material and material.deleted, "不带书架成员标记 → 落库即隐藏身份行，不上架")
    Assert.is_nil(remembered["8801:88011"], "本次没读到的卷不物化")
    Assert.is_nil(remembered["8802:88020"], "容器行缺失 → 跳过物化")
    Assert.eq(findRow(pulled.rows, "book_day", "8802:88020").duration, 300, "容器缺失不影响统计行（照写）")
    Assert.is_nil(remembered["8803"], "单卷系列读在容器行上，不另补行")
    Assert.eq(remembered["8804:88040"] and remembered["8804:88040"].title, "太空漫游 · 太空漫游",
        "目录条目没有卷名时退容器名（fetchToc 给不出时也别留裸 ID）")
    Assert.is_nil(reconciled, "物化不触发书架对账")
    Assert.is_nil(pulled.pulled, "物化不进书架同步结果（只由 stats_changed 刷新展示）")

    -- 物化后卷行真实入库（rememberMany 会落库）：下一轮已存在且无变更 → 不重写（幂等）。
    -- 第二轮必须让核心调 commit 推进状态（真实链路：入库成功才 commit）。状态不前进的话
    -- 章数判定不落盘、目录每轮重读，测不出「第二轮拿不到卷名」的标题回退（旧用例的盲区）。
    books["8801:88010"] = remembered["8801:88010"]
    local state_before_commit = readFile(STATS_STATE)
    Assert.not_nil(state_before_commit, "前一段已经写过状态文件")
    pulled.commit()

    -- 第二轮起目录缓存全清（目录接口也不可用）：卷名只能来自状态文件里的持久化卷名。
    tocs["8801"], tocs["8802"], tocs["8803"], tocs["8804"] = nil, nil, nil, nil
    local history_route = routes["GET /api/Stats/reading-history"]
    routes["GET /api/Stats/reading-history"] = function()
        return json({
            { seriesId = 8801, localDate = "2026-10-10T00:00:00",
                chapters = {
                    { chapterId = 88010, durationSeconds = 600, pagesRead = 1 },
                    -- 本轮新读到的卷：本机还没有书行，标题只能靠持久化卷名
                    { chapterId = 88011, durationSeconds = 300, pagesRead = 0 },
                } },
        }, { Pagination = pagination_header(1, 1) })
    end
    remembered = {}
    run("pullStatsAsync")
    Assert.is_nil(remembered["8801:88010"], "已存在的卷行不重写")
    Assert.eq(remembered["8801:88011"] and remembered["8801:88011"].title, "合集 · 第三卷",
        "第二轮物化标题取状态文件里的持久化卷名，不退容器名")
    local committed = require("luasettings"):open(STATS_STATE)
    local committed_titles = committed:readSetting("titles")
    Assert.eq(committed_titles and committed_titles["8801"] and committed_titles["8801"]["88011"], "第三卷",
        "身份判定时顺带记下的卷名落进状态文件（下次不用再读目录）")
    routes["GET /api/Stats/reading-history"] = history_route

    -- 本地脏行（sync_status=0，本地改过）：物化不动它（沿用卷行先例的 untouched 守卫）。
    books["8801:88010"] = { title = "本地改名", authors = "本地作者", sync_status = 0 }
    remembered = {}
    run("pullStatsAsync")
    Assert.is_nil(remembered["8801:88010"], "本地脏行不重写")
    Assert.eq(books["8801:88010"].title, "本地改名", "本地改的标题留着")

    -- 干净行但字段缺（容器后补的作者还没对齐）：按容器补齐 —— 已存在且**有**变更照写，
    -- 否则首次物化之后容器才补上的作者永远传不到卷行上。
    books["8801:88010"] = { title = "合集 · 第二卷", sync_status = 1 }
    remembered = {}
    run("pullStatsAsync")
    Assert.eq(remembered["8801:88010"] and remembered["8801:88010"].authors, "甲",
        "字段与容器不一致的行对齐一次")

    -- 兜底标题只用于新行：目录 / 状态都给不出卷名时，不能拿容器名盖既有行的真实标题
    -- （升级路径：老状态文件只有章数、没有卷名）。
    books["8804:88040"] = { title = "太空漫游 · 1001", sync_status = 1 }
    remembered = {}
    run("pullStatsAsync")
    Assert.is_nil(remembered["8804:88040"], "无卷名时兜底标题不改写既有标题")
    Assert.eq(books["8804:88040"].title, "太空漫游 · 1001", "既有真实标题保留")

    books["8801"], books["8801:88010"], books["8804:88040"] = nil, nil, nil
    tocs["8801"], tocs["8802"], tocs["8803"], tocs["8804"] = nil, nil, nil, nil
    books["8803"], books["8804"] = nil, nil
    -- 状态恢复成这次 commit 之前的样子：后面的用例（落库时序 / 失败 / 取消）断言的是上段状态。
    local restore = assert(io.open(STATS_STATE, "w"))
    restore:write(state_before_commit)
    restore:close()
    routes["GET /api/Stats/reading-history"] = function()
        return json({ { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 60, pagesRead = 0 } } } },
            { Pagination = pagination_header(1, 1) })
    end
end

-- 落库时序 / 失败 / 取消 / 页数上限：状态只由 commit 推进，失败与取消都不动它。
do
    local day = os.time({ year = 2026, month = 10, day = 10, hour = 0 })
    local before_state = readFile(STATS_STATE)
    Assert.not_nil(before_state, "前一段已经写过状态文件")

    -- 结果交回核心时还没落库：状态先一动不动，等核心入库成功调 commit 才前进。
    routes["GET /api/Stats/reading-history"] = function()
        return json({ { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 600, pagesRead = 0 } } } },
            { Pagination = pagination_header(1, 1) })
    end
    local pulled = run("pullStatsAsync")
    Assert.eq(readFile(STATS_STATE), before_state, "落库前不改状态（失败时身份不前进，孤儿行下次还能清）")
    Assert.len(pulled.replace.books, 2, "replace.books = 上次身份 ∪ 本次身份")
    Assert.contains(pulled.replace.books, "10560:16493")
    Assert.contains(pulled.replace.books, "8661")
    pulled.commit()
    Assert.is_true(readFile(STATS_STATE) ~= before_state, "commit 之后才写状态")

    -- 失败：cb(nil, err)，状态不前进、不建重试队列；本地统计不受影响（核心只记日志）。
    before_state = readFile(STATS_STATE)
    routes["GET /api/Stats/reading-history"] = function() return { code = 500, body = "" } end
    local failed, ferr = run("pullStatsAsync")
    Assert.is_nil(failed)
    Assert.matches(ferr, "500")
    Assert.eq(readFile(STATS_STATE), before_state, "失败不前进状态")

    -- 取消也一样：第二页在飞时取消，迟到的回包不回调、不写状态。
    routes["GET /api/Stats/reading-history"] = function(opts)
        if query(opts, "PageNumber") == "2" then
            return { hold = true, reply = json({}, { Pagination = pagination_header(2, 2) }) }
        end
        return json({ { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 60, pagesRead = 0 } } } },
            { Pagination = pagination_header(1, 2) })
    end
    local called = false
    local job = source:pullStatsAsync(function() called = true end)
    Stubs.flush()
    Assert.len(held, 1, "第二页在飞")
    job:cancel()
    held[#held]()
    Stubs.flush()
    Assert.is_false(called, "取消后不回调")
    Assert.eq(readFile(STATS_STATE), before_state, "取消也不写状态")

    -- 分页头乱报（说 999 页）：页数上限兜底，不无限循环，已经拿到的条目照常入库。
    local capped = 0
    routes["GET /api/Stats/reading-history"] = function()
        capped = capped + 1
        return json({ { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 60, pagesRead = 0 } } } },
            { Pagination = pagination_header(1, 999) })
    end
    local result = run("pullStatsAsync")
    Assert.eq(capped, 50, "页数上限兜底")
    Assert.not_nil(result, "上限只是停止续拉，不是失败")
    Assert.eq(result.rows[1].start_time, day, "已经拉到的页照常入库")
end

-- 框架集成：一次统计同步 = 先本地确认（push）再拉取（pull）落库；dirty_only（推脏）只推不拉。
do
    local pending_stats = { {
        id = 21, source_id = "ext.kavita", stable_id = "8661", record_type = "page", page = 3,
        start_time = 1000, duration = 30, total_pages = 10,
    } }
    local events, marked, replaced = {}, nil, nil
    package.loaded["book.stats_db"] = {
        unsyncedBySource = function() return pending_stats end,
        markSynced = function(ids)
            marked = ids
            events[#events + 1] = "mark"
            pending_stats = {}
            return true
        end,
        replaceSynced = function(source_id, replace, rows)
            events[#events + 1] = "replace"
            replaced = { source_id = source_id, replace = replace, rows = rows }
            return { imported = #rows, skipped = 0 }
        end,
        compactSynced = function() return 0 end,
    }
    routes["GET /api/Stats/reading-history"] = function()
        events[#events + 1] = "http"
        return json({ { seriesId = 8661, localDate = "2026-10-10T00:00:00",
            chapters = { { chapterId = 12763, durationSeconds = 120, pagesRead = 0 } } } },
            { Pagination = pagination_header(1, 1) })
    end

    local result = run("syncStatsAsync", nil)
    Assert.eq(marked[1], 21, "先本地确认本地待同步行")
    Assert.eq(replaced.source_id, "ext.kavita")
    Assert.eq(replaced.rows[1].stable_id, "8661", "拉取的行按云端快照入库")
    Assert.not_nil(replaced.replace, "替换指令一并交给核心")
    Assert.eq(events[1], "mark", "先推后拉：确认落在拉取之前")
    Assert.eq(events[#events], "replace", "最后是落库")
    Assert.eq(result.pushed, 1)
    Assert.eq(result.pulled, #replaced.rows)

    -- dirty_only（推脏队列）：只做本地确认，不发请求——拉取挂在打开 / 切换与手动刷新上。
    pending_stats = { {
        id = 22, source_id = "ext.kavita", stable_id = "8661", record_type = "page", page = 4,
        start_time = 1100, duration = 30, total_pages = 10,
    } }
    marked, replaced, events = nil, nil, {}
    local before_calls = #calls
    run("syncStatsAsync", { dirty_only = true })
    Assert.eq(marked[1], 22, "推脏照样确认本地行")
    Assert.is_nil(replaced, "dirty_only 不拉取、不覆盖")
    Assert.eq(table.concat(events, ","), "mark", "dirty_only 只做本地确认")
    Assert.eq(#calls, before_calls, "dirty_only 零请求")
end

-- 状态文件被写坏（volumes / identities 不是表）：当作没判过，本轮重新判定并从空表重建，
-- 不让存档损坏把整次拉取打断。
do
    local state = require("luasettings"):open(STATS_STATE)
    state:saveSetting("volumes", 42)
    state:saveSetting("identities", "坏")
    state:flush()

    local before_calls = #calls
    local recovered = run("pullStatsAsync")
    Assert.not_nil(recovered, "损坏的状态文件不影响拉取")
    local series_calls = 0
    for idx = before_calls + 1, #calls do
        if calls[idx].url:match("^http://kav/api/Series/8661$") then series_calls = series_calls + 1 end
    end
    Assert.eq(series_calls, 1, "坏档当没判过：重新请求目录判定身份")
    Assert.len(recovered.replace.books, 1, "坏档的 identities 不参与替换范围")
    Assert.contains(recovered.replace.books, "8661")
    recovered.commit()
    state = require("luasettings"):open(STATS_STATE)
    Assert.eq(state:readSetting("volumes")["8661"], 1, "判定结果从空表重建后写回")
end

os.execute("rm -rf '" .. WORK .. "'")
