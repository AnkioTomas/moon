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
for _idx, name in ipairs({ "client", "position", "annotation", "source", "setting", "kamare", "stats" }) do
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

-- 多卷 series 的阅读统计都记在卷行上：容器详情用 statsIdentities 把各卷并进来。
local ids = source:statsIdentities({ source_id = "ext.kavita", stable_id = "20" })
Assert.eq(table.concat(ids or {}, ","), "20:2001,20:2002")
Assert.is_nil(source:statsIdentities({ source_id = "ext.kavita", stable_id = "20:2002" }),
    "卷行只看自己")
Assert.is_nil(source:statsIdentities({ source_id = "ext.kavita", stable_id = "10" }),
    "单卷 series 直接记在 series 行")

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

-- 推送（spec §8）：先按章对账一次，再逐条新建 / 更新；用 do 收住局部变量（Lua 单函数 200 个上限）。
do
    -- 注解：推送前先按章对账一次（一批一次 GET），create 必须拿到 id，写失败整批留脏。
    -- 远端仓库 / 当前用户 / 服务端落库行为全部打桩，断言只看向外的请求与回填。
    local epub = {
        ["META-INF/container.xml"] = [[<rootfile full-path="content.opf"/>]],
        ["content.opf"] = [[<manifest><item id="a" href="a.xhtml"/></manifest><spine><itemref idref="a"/></spine>]],
        ["a.xhtml"] = [[<body><p>春眠不觉晓</p><p>处处闻啼鸟</p></body>]],
    }
    package.loaded["ffi/archiver"] = { Reader = { new = function()
        return {
            open = function(_self, file) return file == WORK .. "/20:2002/2002.epub" end,
            iterate = function() return function() end end,
            extractToMemory = function(_self, name) return epub[name] end,
            close = function() end,
        }
    end } }
    -- 坐标守卫 / 远端赢只留日志：收起来断言，不弹窗也不干扰别的断言。
    local push_warnings = {}
    do
        local log = require("utils.log")
        log.warn = function(...) push_warnings[#push_warnings + 1] = table.concat({ ... }, " ") end
    end
    local function warned(text)
        for _idx, line in ipairs(push_warnings) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    -- 远端注解仓库：GET all 读它，create / update 往里写，bulk-delete 从它删；属主固定成当前用户。
    local USER, next_id = 5, 101
    local remote, created, updated, deleted = {}, {}, {}, {}
    local fail_list, fail_create, fail_update, blank_create, drop_create, create_fail_at
    local fail_delete, reject_delete, list_calls = false, false, 0
    routes["GET /api/Users/me"] = json({ id = USER })
    routes["GET /api/Annotation/all"] = function(opts)
        list_calls = list_calls + 1
        if fail_list then return { code = 500, body = "" } end
        local chapter = tonumber(query(opts, "chapterId")) or 0
        local out = {}
        for _idx, item in ipairs(remote[chapter] or {}) do out[#out + 1] = item end
        return json(out)
    end
    --- 服务端落库：create 分配 id；update 只覆盖可写四字段（坐标改不了，与 Kavita 一致）。
    local function persist(body, is_update)
        local chapter = tonumber(body.chapterId) or 0
        remote[chapter] = remote[chapter] or {}
        local item
        if is_update then
            for _idx, row in ipairs(remote[chapter]) do
                if tonumber(row.id) == tonumber(body.id) then item = row end
            end
        else
            body.id, next_id = next_id, next_id + 1
            body.ownerUserId = USER
            item = body
            remote[chapter][#remote[chapter] + 1] = item
        end
        if item then
            item.comment, item.commentHtml = body.comment, body.commentHtml
            item.selectedSlotIndex, item.containsSpoiler = body.selectedSlotIndex, body.containsSpoiler
        end
        return item
    end
    routes["POST /api/Annotation/create"] = function(opts)
        local body = JSON.decode(opts.body)
        created[#created + 1] = body
        if fail_create or (create_fail_at and #created >= create_fail_at) then return { code = 500, body = "" } end
        local item
        if not drop_create then item = persist(body, false) end
        -- blank_create：反代吞掉 DTO（2xx 空体），但服务端确实建成了。
        if blank_create or not item then return { code = 200, body = "" } end
        return json({ id = item.id })
    end
    routes["POST /api/Annotation/update"] = function(opts)
        local body = JSON.decode(opts.body)
        updated[#updated + 1] = body
        if fail_update then return { code = 500, body = "" } end
        persist(body, true)
        return json({ id = body.id })
    end
    -- 删除：body 是裸 id 数组；不存在的 id 静默忽略（与 Kavita 一致）。
    -- reject_delete 用来模拟「不是你的 / 服务端拒绝」的 400 分支。
    routes["POST /api/Annotation/bulk-delete"] = function(opts)
        local ids = JSON.decode(opts.body)
        deleted[#deleted + 1] = ids
        if fail_delete then return { code = 500, body = "" } end
        if reject_delete then return { code = 400, body = "" } end
        local wanted = {}
        for _idx, id in ipairs(ids) do wanted[tonumber(id)] = true end
        for _chapter, rows in pairs(remote) do
            for i = #rows, 1, -1 do
                if wanted[tonumber(rows[i].id)] then table.remove(rows, i) end
            end
        end
        return { code = 200, body = "" }
    end
    --- 每个场景从干净状态开始：远端仓库、写请求计数、故障开关。
    local function resetPush()
        remote, next_id, created, updated, deleted = {}, 101, {}, {}, {}
        fail_list, fail_create, fail_update = false, false, false
        blank_create, drop_create, create_fail_at = false, false, nil
        fail_delete, reject_delete, list_calls = false, false, 0
        push_warnings = {}
    end

    -- 非 epub：零请求，pushed=0（核心据此不谎报「同步过」）。
    resetPush()
    local calls_before = #calls
    local ok_epub, _err_epub, data_epub = run("pushNotesAsync", pdf,
        { { drawer = "lighten", text = "图", pos0 = "x" } })
    Assert.is_true(ok_epub)
    Assert.eq(data_epub.pushed, 0)
    Assert.eq(#calls, calls_before, "非 epub 一个请求都不发")

    -- 对账 GET 失败：宁可这轮不推，也不盲建重复；一个写请求都不发。
    resetPush()
    fail_list = true
    local ok_net, err_net = run("pushNotesAsync", volume,
        { { drawer = "lighten", text = "春眠\n不觉晓", note = "好诗", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" } })
    Assert.is_nil(ok_net)
    Assert.matches(err_net, "500")
    Assert.len(created, 0)
    Assert.len(updated, 0)

    -- 新建：请求体按 §5.1 的 Web 兼容形态；成功判据是 DTO 里有 id，id 原地回填给核心落库。
    resetPush()
    local anns = {
        { drawer = "lighten", text = "春眠\n不觉晓", note = "好诗", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" },
        { drawer = "underscore", text = "处处闻啼鸟", pos0 = "/body/DocFragment[1]/body/p[2]/text().0" },
    }
    local ok_new, err_new, data_new = run("pushNotesAsync", volume, anns)
    Assert.is_true(ok_new)
    Assert.is_nil(err_new)
    Assert.eq(data_new.pushed, 2)
    Assert.eq(data_new.adopted, 0)
    Assert.len(created, 2)
    Assert.len(updated, 0)
    Assert.eq(created[1].xPath, "//body/p[1]")
    Assert.eq(created[1].endingXPath, "//body/p[1]")
    Assert.eq(created[1].pageNumber, 0)
    Assert.eq(created[1].selectedText, "春眠\n不觉晓")
    Assert.eq(created[1].highlightCount, 6, "按 UTF-16 码元计")
    Assert.eq(created[1].chapterId, 2002)
    Assert.eq(created[1].volumeId, 201)
    Assert.eq(created[1].libraryId, 2)
    Assert.eq(created[1].seriesId, 20)
    Assert.eq(JSON.decode(created[1].comment).ops[1].insert, "好诗\n", "备注写 Quill Delta，网页端才打得开")
    Assert.eq(created[1].commentHtml, "<p>好诗</p>")
    Assert.eq(created[2].comment, "{}", "空备注写空 Delta（网页端 JSON.parse 不崩）")
    Assert.eq(created[2].commentHtml, "")
    Assert.eq(anns[1].kavita_id, 101)
    Assert.eq(anns[1].kavita_note, "好诗")
    Assert.eq(anns[1].kavita_xpath, "//body/p[1]", "远端坐标回填给诊断与坐标守卫")
    Assert.eq(anns[2].kavita_id, 102)
    Assert.eq(anns[2].kavita_note, "", "空备注的基线是空串，不是 nil（否则每轮都判改过）")

    -- 再推一轮：没有改动 → 零请求，pushed=0。
    created, updated = {}, {}
    local ok_same, _err_same, data_same = run("pushNotesAsync", volume, anns)
    Assert.is_true(ok_same)
    Assert.eq(data_same.pushed, 0)
    Assert.len(created, 0, "推过的不重建")
    Assert.len(updated, 0)

    -- 改备注且远端没变 → 一次 update（整条替换）；未改动的槽位 / 剧透回传远端原值。
    anns[1].kavita_slot, anns[1].kavita_spoiler = 3, true
    anns[1].note = "改了"
    local ok_up, _err_up, data_up = run("pushNotesAsync", volume, anns)
    Assert.is_true(ok_up)
    Assert.eq(data_up.pushed, 1)
    Assert.eq(data_up.adopted, 0, "update 是写入，只算 pushed；adopted 只数「认到 id 但没写」")
    Assert.eq(data_up.conflicts, 0)
    Assert.len(updated, 1)
    Assert.eq(updated[1].id, 101)
    Assert.eq(updated[1].xPath, "//body/p[1]", "update 也带坐标（服务端忽略，形状要对）")
    Assert.eq(JSON.decode(updated[1].comment).ops[1].insert, "改了\n")
    Assert.eq(updated[1].selectedSlotIndex, 3, "颜色不回传就会被服务端清成默认")
    Assert.eq(updated[1].containsSpoiler, true)
    Assert.eq(anns[1].kavita_note, "改了")

    -- 坐标守卫：现算锚点与远端记录不一致 → 跳过 update 并留日志（服务端改不了坐标，硬发会写到旧位置）。
    anns[1].note = "坐标漂了"
    anns[1].kavita_xpath = "//body/p[9]"
    local ok_guard, _err_guard, data_guard = run("pushNotesAsync", volume, anns)
    Assert.is_true(ok_guard)
    Assert.eq(data_guard.pushed, 0)
    Assert.len(updated, 1, "坐标不一致不 update")
    Assert.is_true(warned("drifted"), "跳过的原因要能在日志里定位")
    Assert.eq(anns[1].kavita_note, "改了", "没写成功，基线不能动")
    anns[1].kavita_xpath = nil

    -- 双方都改过：远端赢，零写请求；本地文本存 kavita_local_note 备查，基线不动（等下轮 pull 采纳远端）。
    anns[1].note, anns[1].kavita_note = "设备改的", "上次同步"
    remote[2002][1].comment, remote[2002][1].commentHtml = nil, "<p>网页改的</p>"
    local ok_lose, _err_lose, data_lose = run("pushNotesAsync", volume, anns)
    Assert.is_true(ok_lose)
    Assert.eq(data_lose.pushed, 0)
    Assert.eq(data_lose.conflicts, 1)
    Assert.len(updated, 1)
    Assert.eq(anns[1].kavita_local_note, "设备改的")
    Assert.eq(anns[1].kavita_note, "上次同步")
    Assert.is_true(warned("remote"), "远端赢要留日志")

    -- 对账列表按 ownerUserId 收窄：账号开了「查看他人注解」后混进来的条目不能被认领 / 改写。
    resetPush()
    remote[2002] = { { id = 5, ownerUserId = 99, chapterId = 2002, xPath = "//body/p[1]", endingXPath = "//body/p[1]",
        selectedText = "春眠\n不觉晓", commentHtml = "<p>别人</p>" } }
    local mine = { drawer = "lighten", text = "春眠\n不觉晓", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    Assert.is_true(run("pushNotesAsync", volume, { mine }))
    Assert.eq(mine.kavita_id, 101, "别人的同键注解不认领")
    Assert.len(created, 1)

    -- 首次认领：本地没 id、远端同键已有 → 采纳（同键多条取 id 最小），不新建。
    resetPush()
    remote[2002] = {
        { id = 43, ownerUserId = USER, chapterId = 2002, xPath = "//body/p[1]", endingXPath = "//body/p[1]",
            selectedText = "春眠\n不觉晓", commentHtml = "<p>重复</p>" },
        { id = 37, ownerUserId = USER, chapterId = 2002, xPath = "//body/p[1]", endingXPath = "//body/p[1]",
            selectedText = "春眠 不觉晓", commentHtml = "<p>网页写的</p>" },
    }
    local claimed = { drawer = "lighten", text = "春眠\n不觉晓", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local ok_claim, _err_claim, data_claim = run("pushNotesAsync", volume, { claimed })
    Assert.is_true(ok_claim)
    Assert.eq(claimed.kavita_id, 37, "同键多条取 id 最小")
    Assert.is_nil(claimed.kavita_note, "远端备注不当基线：本地 note 还是空的，等 pull 采纳")
    Assert.eq(data_claim.pushed, 0)
    Assert.eq(data_claim.adopted, 1, "只认领 id、没写远端 → adopted")
    Assert.len(created, 0)
    Assert.len(updated, 0, "首次认领不覆盖远端非空备注")

    -- 认领过的那条再推（本地 note 仍空、pull 还没跑）→ 零写请求。
    -- 基线若被写成远端文本，这里就会被判成「用户清空了备注」，一次 update 抹掉网页作者的内容。
    local ok_again, _err_again, data_again = run("pushNotesAsync", volume, { claimed })
    Assert.is_true(ok_again)
    Assert.eq(data_again.pushed, 0)
    Assert.len(updated, 0, "认领后不能反手把远端的备注覆盖成空")

    -- 认领后、pull 之前用户补了备注 → 这是真实编辑，直接 update（没有基线不等于冲突）。
    local later = { drawer = "lighten", text = "春眠\n不觉晓", note = "补的备注", kavita_id = 37,
        pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    Assert.is_true(run("pushNotesAsync", volume, { later }))
    Assert.eq(updated[#updated].id, 37)
    Assert.eq(JSON.decode(updated[#updated].comment).ops[1].insert, "补的备注\n")
    Assert.eq(later.kavita_note, "补的备注")

    -- 首次认领时本地备注非空且不同 → 认到 id 后 update 那一条（设备侧确实改了备注）。
    local named = { drawer = "lighten", text = "春眠\n不觉晓", note = "我的备注",
        pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    Assert.is_true(run("pushNotesAsync", volume, { named }))
    Assert.eq(named.kavita_id, 37)
    Assert.eq(updated[#updated].id, 37, "首次认领不新建")
    Assert.eq(JSON.decode(updated[#updated].comment).ops[1].insert, "我的备注\n")
    Assert.eq(named.kavita_note, "我的备注")

    -- 有 id、远端已无该 id（网页端删了）→ 不重建、不复活（交给 pull 的 dropped 通道）。
    local ghost = { drawer = "lighten", text = "春眠\n不觉晓", note = "改过", kavita_id = 99, kavita_note = "旧",
        pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local writes_before = #created + #updated
    Assert.is_true(run("pushNotesAsync", volume, { ghost }))
    Assert.eq(#created + #updated, writes_before, "远端删了不重建")
    Assert.eq(ghost.kavita_id, 99)
    Assert.is_nil(ghost.kavita_local_note)

    -- 本批墓碑的 id 先剔出对账列表：删了又原地划一条同键的，不能认领到「即将删除」的那条。
    -- 先写后删：新建成功后一次 bulk-delete 删掉旧 id，远端最终只剩新建的那条。
    remote[2002] = { { id = 37, ownerUserId = USER, chapterId = 2002, xPath = "//body/p[1]", endingXPath = "//body/p[1]",
        selectedText = "春眠\n不觉晓", commentHtml = "<p>旧</p>" } }
    local tomb = { kavita_id = 37, kavita_deleted = true, datetime = "2026-10-01" }
    local redo = { drawer = "lighten", text = "春眠\n不觉晓", note = "新的", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local redo_batch = { tomb, redo }
    Assert.is_true(run("pushNotesAsync", volume, redo_batch))
    Assert.is_true(redo.kavita_id ~= 37, "墓碑那条不在认领范围内")
    Assert.eq(redo.kavita_id, 101, "同键的划线重建一条")
    Assert.eq(#deleted, 1)
    Assert.eq(deleted[1][1], 37, "body 是裸 id 数组")
    Assert.eq(#redo_batch, 1, "删除成功后墓碑从 payload 出列")
    Assert.eq(redo_batch[1], redo)
    Assert.eq(#remote[2002], 1, "删一条 + 原地划一条同键：远端只剩新建的那条")
    Assert.eq(remote[2002][1].id, 101)

    -- 删除高亮：墓碑单独一批也能推（没有 create/update），200 即出列、远端少一条；
    -- 墓碑出列后再推一轮是零请求。
    resetPush()
    remote[2002] = { { id = 51, ownerUserId = USER, chapterId = 2002, selectedText = "旧划线",
        commentHtml = "", comment = "" } }
    local only_tomb = { { kavita_id = 51, kavita_deleted = true, datetime = "2026-10-01" } }
    local ok_del, _err_del, data_del = run("pushNotesAsync", volume, only_tomb)
    Assert.is_true(ok_del)
    Assert.eq(data_del.pushed, 0)
    Assert.eq(data_del.deleted, 1, "deleted 如实计数")
    Assert.eq(deleted[1][1], 51)
    Assert.len(only_tomb, 0, "墓碑出列")
    Assert.len(remote[2002], 0, "远端确实少一条")
    local quiet_before = #calls
    local ok_quiet, _err_quiet, data_quiet = run("pushNotesAsync", volume, only_tomb)
    Assert.is_true(ok_quiet)
    Assert.eq(data_quiet.deleted, 0)
    Assert.eq(#calls, quiet_before, "墓碑已出列，再推零请求")

    -- 远端早就没有这个 id（别处删过 / 从没推成功）：bulk-delete 回 200 一样出列，不报错。
    resetPush()
    local ghost_tomb = { { kavita_id = 999, kavita_deleted = true, datetime = "d" } }
    local ok_idem, _err_idem, data_idem = run("pushNotesAsync", volume, ghost_tomb)
    Assert.is_true(ok_idem)
    Assert.eq(data_idem.deleted, 1)
    Assert.len(ghost_tomb, 0, "远端已删的墓碑幂等出列")

    -- 删除失败（非 400）：整批 cb(nil)，墓碑留在 payload 里；下轮重试成功才出列。
    resetPush()
    remote[2002] = { { id = 52, ownerUserId = USER, chapterId = 2002, selectedText = "旧",
        commentHtml = "", comment = "" } }
    local retry_tomb = { { kavita_id = 52, kavita_deleted = true, datetime = "d" } }
    fail_delete = true
    local ok_retry, err_retry = run("pushNotesAsync", volume, retry_tomb)
    Assert.is_nil(ok_retry)
    Assert.matches(err_retry, "500")
    Assert.len(retry_tomb, 1, "失败时墓碑保留，快照留脏")
    Assert.len(remote[2002], 1)
    fail_delete = false
    local ok_again_del, _err_again_del, data_again_del = run("pushNotesAsync", volume, retry_tomb)
    Assert.is_true(ok_again_del)
    Assert.eq(data_again_del.deleted, 1, "重试成功")
    Assert.len(retry_tomb, 0)
    Assert.len(remote[2002], 0)

    -- 写失败时一个删除都不发：先写后删，写入不留半成品删除。
    resetPush()
    remote[2002] = { { id = 53, ownerUserId = USER, chapterId = 2002, selectedText = "旧",
        commentHtml = "", comment = "" } }
    fail_create = true
    local write_fail_batch = {
        { kavita_id = 53, kavita_deleted = true, datetime = "d" },
        { drawer = "lighten", text = "春眠\n不觉晓", note = "a", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" },
    }
    local ok_wf, err_wf = run("pushNotesAsync", volume, write_fail_batch)
    Assert.is_nil(ok_wf)
    Assert.matches(err_wf, "500")
    Assert.len(deleted, 0, "create 失败就不发删除")
    Assert.len(write_fail_batch, 2, "墓碑保留")

    -- 400（服务端拒绝 / 不是你的）→ 重拉一次该章列表，仍在那里的丢弃墓碑并记日志，不无限重试。
    resetPush()
    remote[2002] = { { id = 54, ownerUserId = USER, chapterId = 2002, selectedText = "删不掉",
        commentHtml = "", comment = "" } }
    reject_delete = true
    local rejected_tomb = { { kavita_id = 54, kavita_deleted = true, datetime = "d" } }
    local ok_rej, _err_rej, data_rej = run("pushNotesAsync", volume, rejected_tomb)
    Assert.is_true(ok_rej, "400 按对账结果收尾，不让整批反复失败")
    Assert.eq(data_rej.deleted, 0, "远端还在，不算删成功")
    Assert.len(rejected_tomb, 0, "仍在列表里的墓碑丢弃，下轮不再重试")
    Assert.is_true(warned("delete rejected"), "丢弃要有日志")
    Assert.eq(list_calls, 2, "400 后重拉一次该章列表")
    Assert.len(remote[2002], 1, "远端那条原样保留")
    local after_rej = #calls
    Assert.is_true(run("pushNotesAsync", volume, rejected_tomb))
    Assert.eq(#calls, after_rej, "不再有墓碑就零请求")

    -- 400 且 id 已不在列表里 → 目标态已达成，墓碑出列并计入 deleted。
    resetPush()
    reject_delete = true
    local gone_tomb = { { kavita_id = 55, kavita_deleted = true, datetime = "d" } }
    local ok_gone, _err_gone, data_gone = run("pushNotesAsync", volume, gone_tomb)
    Assert.is_true(ok_gone)
    Assert.eq(data_gone.deleted, 1, "不在列表里 = 已经删掉")
    Assert.len(gone_tomb, 0)

    -- create 回空体（反代吞了 DTO）：§8.3 的补偿只查**同一轮**对账列表（一批一次 GET），
    -- 那份列表是创建前取的、里面没有刚建的这条 → 无法确认，该条失败留脏，不为它再补发一次 GET。
    resetPush()
    blank_create = true
    local lone = { drawer = "lighten", text = "春眠\n不觉晓", note = "n", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local ok_blank, err_blank = run("pushNotesAsync", volume, { lone })
    Assert.is_nil(ok_blank, "无 id 的 2xx 不算成功")
    Assert.not_nil(err_blank)
    Assert.is_nil(lone.kavita_id, "没确认到 id 就不回填")
    Assert.eq(list_calls, 1, "一批只对一次账：回空体不再补发 GET")
    -- 下一轮对账就能看到服务端其实落了那条：按 key 认领，不重复建。
    blank_create = false
    created = {}
    Assert.is_true(run("pushNotesAsync", volume, { lone }))
    Assert.eq(lone.kavita_id, 101, "下轮对账按 key 认领，回填 id")
    Assert.len(created, 0, "认到同键就不新建")
    Assert.len(remote[2002], 1, "远端最终只有一条")

    -- 回查也找不到（服务端真没落库）→ 该条失败、整批 cb(nil) 留脏，绝不当成功。
    resetPush()
    drop_create = true
    local dropped_ann = { drawer = "lighten", text = "春眠\n不觉晓", note = "n",
        pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local ok_drop, err_drop = run("pushNotesAsync", volume, { dropped_ann })
    Assert.is_nil(ok_drop)
    Assert.not_nil(err_drop)
    Assert.is_nil(dropped_ann.kavita_id)

    -- 全有或全无：一条写失败 → 整批 cb(nil)；已建成的条目下轮由对账认领，不会重复。
    resetPush()
    local first = { drawer = "lighten", text = "春眠\n不觉晓", note = "a", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local second = { drawer = "lighten", text = "处处闻啼鸟", note = "b", pos0 = "/body/DocFragment[1]/body/p[2]/text().0" }
    create_fail_at = 2
    local ok_fail, err_fail = run("pushNotesAsync", volume, { first, second })
    Assert.is_nil(ok_fail)
    Assert.matches(err_fail, "500")
    Assert.eq(first.kavita_id, 101)
    Assert.is_nil(second.kavita_id)
    first.kavita_id = nil -- cb(nil) 后核心不落库，这条 id 就丢了
    create_fail_at = nil
    created, updated = {}, {}
    Assert.is_true(run("pushNotesAsync", volume, { first, second }))
    Assert.eq(first.kavita_id, 101, "上轮已建成的条目由对账按 key 认领")
    Assert.len(created, 1, "只补建真正缺的那条")
    Assert.eq(second.kavita_id, 102)

    -- 锚点失败（找不回段落）：不带空 xPath 发出去（会跟别的空锚点挤成同键），整批不发送、留脏重试。
    resetPush()
    local good = { drawer = "lighten", text = "春眠\n不觉晓", note = "a", pos0 = "/body/DocFragment[1]/body/p[1]/text().0" }
    local lost = { drawer = "lighten", text = "𠀀找不到", pos0 = "/body/DocFragment[3]/body/p/text().0" }
    local ok_lost, err_lost = run("pushNotesAsync", volume, { good, lost })
    Assert.is_nil(ok_lost)
    Assert.not_nil(err_lost)
    Assert.len(created, 0, "锚点不齐就一个都不发")
    Assert.len(updated, 0)

    -- 书签（没有 drawer）不推，也不算失败。
    resetPush()
    local ok_mark, _err_mark, data_mark = run("pushNotesAsync", volume,
        { { text = "书签", pos0 = "/body/DocFragment[1]/body/p" } })
    Assert.is_true(ok_mark)
    Assert.eq(data_mark.pushed, 0)
    Assert.len(created, 0)

    -- 快照：清洗保留 Kavita 全字段（白名单漏一个就静默消失），保存时按 pos0 从上一版接过 id。
    local clean = source:cleanAnnotations({
        { datetime = "d", page = 1, drawer = "lighten", text = "x", pos0 = "p", kavita_id = 71, kavita_note = "n", junk = 1,
            pageNumber = 3,
            kavita_comment = "{}", kavita_comment_html = "", kavita_slot = 0, kavita_spoiler = false,
            kavita_modified = "m", kavita_xpath = "//body/p[1]", kavita_ending_xpath = "//body/p[1]",
            kavita_unlocated = true, kavita_local_note = "被远端覆盖的旧文本" },
        { text = "没有时间的丢掉" },
    }, 10)
    Assert.len(clean, 1)
    Assert.eq(clean[1].kavita_id, 71)
    Assert.eq(clean[1].pageNumber, 3, "pageNumber 不是 kavita_ 前缀，但也必须过白名单（定位提示）")
    Assert.eq(clean[1].kavita_note, "n")
    Assert.eq(clean[1].kavita_comment, "{}")
    Assert.eq(clean[1].kavita_comment_html, "")
    Assert.eq(clean[1].kavita_slot, 0)
    Assert.eq(clean[1].kavita_spoiler, false)
    Assert.eq(clean[1].kavita_modified, "m")
    Assert.eq(clean[1].kavita_xpath, "//body/p[1]")
    Assert.eq(clean[1].kavita_ending_xpath, "//body/p[1]")
    Assert.is_true(clean[1].kavita_unlocated)
    Assert.eq(clean[1].kavita_local_note, "被远端覆盖的旧文本")
    Assert.eq(clean[1].total_pages, 10)
    Assert.is_nil(clean[1].junk, "白名单外的字段仍丢弃")

    -- 无 page 的两类条目必须放行：未定位（只有 xPath）、墓碑（只有 kavita_deleted）。
    -- 靠「构造期用 xPath / 墓碑标记当占位」过 Normalize.clean，清洗后把占位清空。
    local unlocated = source:cleanAnnotations({
        { datetime = "d", text = "云端条", note = "", kavita_id = 72, kavita_xpath = "//body/p[9]" },
        { datetime = "d", kavita_id = 73, kavita_deleted = true },
        { datetime = "d", text = "没有任何坐标" },
    }, 10)
    Assert.len(unlocated, 2, "无时间 / 无坐标的条目仍然丢掉")
    Assert.eq(unlocated[1].kavita_id, 72)
    Assert.eq(unlocated[1].kavita_xpath, "//body/p[9]", "未定位条目保留全部 kavita_* 字段")
    Assert.is_nil(unlocated[1].page, "占位只在构造期用，清洗后清空")
    Assert.eq(unlocated[1].total_pages, 10)
    Assert.eq(unlocated[2].kavita_id, 73)
    Assert.is_true(unlocated[2].kavita_deleted)
    Assert.is_nil(unlocated[2].page)

    -- 保存时：pos0 对得上的接过 id；没有 pos0 的未定位条目原样搬进新快照，
    -- 否则一次普通保存就把「数据在、画不出」的云端条目洗掉。
    local previous = {
        { pos0 = "p", kavita_id = 71, kavita_note = "n" },
        { pos0 = "gone", kavita_id = 9, datetime = "d-gone" },
        { datetime = "d", text = "云端条", kavita_id = 72, kavita_note = "", kavita_xpath = "//body/p[9]" },
    }
    local current = source:prepareLocalAnnotations(previous,
        { { pos0 = "p", note = "新" }, { pos0 = "q" } })
    Assert.eq(current[1].kavita_id, 71)
    Assert.eq(current[1].kavita_note, "n", "备注差异留给推送时比对")
    Assert.is_nil(current[2].kavita_id)
    Assert.eq(#current, 3, "未定位条目搬进新快照")
    Assert.eq(current[3].kavita_id, 72)
    Assert.eq(current[3].kavita_xpath, "//body/p[9]")
    Assert.is_nil(current[3].pos0)
    local deduped = source:prepareLocalAnnotations(previous,
        { { pos0 = "p", note = "新" }, { kavita_id = 72, text = "已经在快照里" } })
    Assert.eq(#deduped, 2, "快照里已有的 id 不重复搬")

    -- 本地删除（spec §9.1）：被删条目按 pos0 在上一版里找到、且那条有 id → 追加墓碑。
    -- 墓碑不带 pos/page（画不出来），但带 id 与基线备注；阅读器与 doc_settings 都不画它。
    local with_id = source:prepareLocalAnnotations(previous,
        { { pos0 = "p", note = "新" } }, { pos0 = "gone", text = "删了" })
    Assert.eq(#with_id, 3, "剩余条目 + 未定位条目 + 墓碑")
    local tomb = with_id[3]
    Assert.is_true(tomb.kavita_deleted)
    Assert.eq(tomb.kavita_id, 9, "墓碑按 pos0 取上一版那条的 id")
    Assert.is_nil(tomb.pos0, "墓碑没有坐标")
    Assert.eq(tomb.datetime, "d-gone")

    -- 被删的是划线转笔记 / 只删备注：条目还在，删除事件判据不成立（changed 传 nil）→ 无墓碑。
    local note_change = source:prepareLocalAnnotations(previous,
        { { pos0 = "p", note = "改成笔记" }, { pos0 = "gone", note = "还在" } })
    Assert.eq(#note_change, 3, "条目仍在快照里，不产生墓碑")
    for _idx, item in ipairs(note_change) do Assert.is_nil(item.kavita_deleted) end

    -- 没 id 的本地划线被删：本来就没推到远端 → 不产生墓碑；pos0 对不上 / 没 pos0 同理（只漏删不误删）。
    local no_id_previous = { { pos0 = "local", text = "纯本地", datetime = "d" } }
    local no_id = source:prepareLocalAnnotations(no_id_previous, {},
        { pos0 = "local", text = "纯本地" })
    Assert.len(no_id, 0, "无 id 的删除不生成墓碑")
    local no_pos = source:prepareLocalAnnotations(previous, {}, { text = "没有坐标" })
    Assert.len(no_pos, 1, "没有 pos0：只剩未定位条目，不生成墓碑")
    local miss = source:prepareLocalAnnotations(previous, {}, { pos0 = "other", text = "对不上" })
    Assert.len(miss, 1, "pos0 在上一版找不到就不生成墓碑")

    -- 后续保存从上一版重新接上墓碑，直到推送成功把它清掉；已有 id 的不重复搬。
    local with_tomb_previous = {
        { pos0 = "p", kavita_id = 71, kavita_note = "n" },
        { datetime = "d", kavita_id = 9, kavita_deleted = true },
    }
    local reattached = source:prepareLocalAnnotations(with_tomb_previous,
        { { pos0 = "p", note = "新" } })
    Assert.eq(#reattached, 2)
    Assert.is_true(reattached[2].kavita_deleted)
    Assert.eq(reattached[2].kavita_id, 9)
end

-- 远端删除回流（spec §9.2）：seen 按远端**全量** id 建，未定位条目仍占位；
-- 输出只画可渲染的远端条目；本地带 id 但远端没有 → 丢弃并计入 dropped。
do
    local remote = {
        { datetime = "d1", page = "/body/p[1].0", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5",
            drawer = "lighten", text = "远端还在", kavita_id = 1 },
        { datetime = "d2", kavita_id = 2, kavita_xpath = "//body/p[2]", kavita_unlocated = true },
    }
    local current = {
        { datetime = "d1", page = "/body/p[1].0", pos0 = "/body/p[1].0", pos1 = "/body/p[1].5",
            drawer = "lighten", text = "远端还在", kavita_id = 1 },
        { datetime = "d2", page = "/body/p[2].0", pos0 = "/body/p[2].0", pos1 = "/body/p[2].5",
            drawer = "lighten", text = "本地定位过", kavita_id = 2 },
        { datetime = "d3", page = "/body/p[3].0", pos0 = "/body/p[3].0", pos1 = "/body/p[3].5",
            drawer = "lighten", text = "远端删了", kavita_id = 3 },
        { datetime = "d4", page = "/body/p[4].0", pos0 = "/body/p[4].0", pos1 = "/body/p[4].5",
            drawer = "lighten", text = "纯本地" },
    }
    local merged, dropped = source:mergeAnnotations(remote, current, nil, false)
    Assert.eq(#merged, 3, "远端已定位 1 条 + 未定位的本地副本 + 纯本地 1 条")
    Assert.eq(merged[1].kavita_id, 1)
    Assert.eq(merged[2].kavita_id, 2, "未定位远端不画，但本地已定位的那条保留")
    Assert.is_nil(merged[3].kavita_id)
    Assert.eq(dropped, 1, "只有远端确实没有的 id 算 dropped")
    for _idx, item in ipairs(merged) do Assert.is_true(item.kavita_id ~= 3) end

    -- 远端条目与本地同 id 只画远端那份（本地被替换），不算删除。
    local replaced, replaced_dropped = source:mergeAnnotations(
        { remote[1] }, { { datetime = "d1", page = "old", pos0 = "old", pos1 = "old",
            drawer = "lighten", text = "本地旧坐标", kavita_id = 1 } }, nil, false)
    Assert.eq(#replaced, 1)
    Assert.eq(replaced[1].page, "/body/p[1].0")
    Assert.eq(replaced_dropped, 0)

    -- 离线 / 未定位全败：远端列表为空但本地都没有 id 时一条都不丢。
    local kept, kept_dropped = source:mergeAnnotations({}, {
        { datetime = "d4", page = "/body/p[4].0", pos0 = "/body/p[4].0", pos1 = "/body/p[4].5",
            drawer = "lighten", text = "纯本地" },
    }, nil, false)
    Assert.eq(#kept, 1)
    Assert.eq(kept_dropped, 0, "离线没有 id 集合时不判删除")
end

-- 远端同键重复（历史推送窗口的产物：真书 7460:11285 的 id 37 / 43 同 xPath 同文本，
-- spec §6「同键多条取 id 最小」/ §13.1 B）：只画 id 最小那条，其余不渲染、也不当远端已删。
do
    local XPATH = "//body/DocFragment[24]/body/div[3]/p[2]"
    local function remoteAnn(id, over)
        local item = {
            datetime = "d", page = "/body/p[24].0", pos0 = "/body/p[24].0", pos1 = "/body/p[24].5",
            drawer = "lighten", text = "既替余以蕙纕兮", kavita_id = id,
            kavita_xpath = XPATH, kavita_ending_xpath = XPATH,
        }
        for key, value in pairs(over or {}) do item[key] = value end
        return item
    end
    local a37, a43 = remoteAnn(37), remoteAnn(43)

    local one, one_dropped, one_deduped = source:mergeAnnotations({ a37, a43 }, {}, nil, false)
    Assert.eq(#one, 1, "同键两条只画一条")
    Assert.eq(one[1].kavita_id, 37, "同键取 id 最小")
    Assert.eq(one_dropped, 0, "去重不是远端删除")
    Assert.eq(one_deduped, 1, "被抑制的远端条数走第三返回值")

    local reversed, r_dropped, r_deduped = source:mergeAnnotations({ a43, a37 }, {}, nil, false)
    Assert.eq(#reversed, 1)
    Assert.eq(reversed[1].kavita_id, 37, "倒序输入仍取 id 最小")
    Assert.eq(r_dropped, 0)
    Assert.eq(r_deduped, 1)

    -- 不同键的两条都保留（去重键不能退化成「一章一条」）。
    local other = remoteAnn(44, {
        kavita_xpath = "//body/DocFragment[24]/body/div[3]/p[3]",
        kavita_ending_xpath = "//body/DocFragment[24]/body/div[3]/p[3]",
        text = "另一段划线",
    })
    local both, both_dropped, both_deduped = source:mergeAnnotations({ a37, other }, {}, nil, false)
    Assert.eq(#both, 2)
    Assert.eq(both_dropped, 0)
    Assert.eq(both_deduped, 0)

    -- 旧 doc_settings 里还留着一条带 43 的本地副本：远端 43 被抑制（id 仍在全量集合里），
    -- 本地那份不能再画一遍，也不能算 dropped —— 否则合法去重会被条数保护当成远端删除。
    local local43 = {
        datetime = "d", page = "/body/old.0", pos0 = "/body/old.0", pos1 = "/body/old.5",
        drawer = "lighten", text = "既替余以蕙纕兮", kavita_id = 43,
    }
    local single, s_dropped, s_deduped = source:mergeAnnotations({ a37, a43 }, { local43 }, nil, false)
    Assert.eq(#single, 1, "本地 43 不重复渲染")
    Assert.eq(single[1].kavita_id, 37, "画的是 id 最小那条")
    Assert.eq(s_dropped, 0, "远端 43 只是被抑制，不算远端已删")
    Assert.eq(s_deduped, 1)
end

-- 拉取：开书时把云端 epub 注解落库（入库不定位）。每章一次 GET，按 ownerUserId 收窄；
-- authoritative 恒 false（远端为空不代表本地该清空），失败就 cb(nil, err)，快照不动。
local ann_calls = {}
local remote_anns = {
    {   -- 网页端写的：Delta + HTML + 纯文本都有；颜色槽 2 = blue。
        id = 501, ownerUserId = 5, chapterId = 2002,
        xPath = "//body/p[1]", endingXPath = "//body/p[1]",
        selectedText = "春眠不觉晓",
        comment = '{"ops":[{"insert":"记一笔\\n"}]}',
        commentHtml = "<p>记一笔</p>", commentPlainText = "记一笔",
        selectedSlotIndex = 2, containsSpoiler = true,
        createdUtc = os.date("!%Y-%m-%dT%H:%M:%S", 1790000000) .. ".789",
        lastModifiedUtc = "2026-10-04T05:06:07.890",
        pageNumber = 17,
    },
    {   -- 别人的注解：账号开了「查看他人注解」时接口会混进来，拉取必须按 owner 过滤。
        id = 502, ownerUserId = 9, chapterId = 2002,
        xPath = "//body/p[2]", endingXPath = "//body/p[2]", selectedText = "别人的划线",
        comment = "", commentHtml = "", selectedSlotIndex = 0,
        createdUtc = "2026-10-03T05:00:00",
    },
    {   -- 裸高亮：没有备注，槽位越界 → yellow。
        id = 503, ownerUserId = 5, chapterId = 2002,
        xPath = "//body/p[2]", endingXPath = "//body/p[3]",
        selectedText = "处处闻啼鸟",
        comment = "", commentHtml = "", commentPlainText = "",
        selectedSlotIndex = 9, containsSpoiler = false,
        createdUtc = "2026-10-03T05:00:00",
    },
}
routes["GET /api/Users/me"] = json({ id = 5, username = "me" })
routes["GET /api/Annotation/all"] = function(opts)
    ann_calls[#ann_calls + 1] = opts
    return json(remote_anns)
end
local pulled, perr, pmeta = run("pullNotesAsync", volume)
Assert.eq(#ann_calls, 1, "每章一次 GET")
Assert.eq(query(ann_calls[1], "chapterId"), "2002")
Assert.eq(#pulled, 2, "只留自己的注解")
Assert.is_nil(perr)
Assert.is_false(pmeta.authoritative, "authoritative 恒 false：远端为空不清本地")

local web = pulled[1]
Assert.eq(web.kavita_id, 501)
Assert.eq(web.text, "春眠不觉晓")
Assert.eq(web.note, "记一笔")
Assert.eq(web.kavita_note, web.note, "kavita_note 与 note 必须字节相同，否则每轮判改过")
Assert.eq(web.datetime, os.date("%Y-%m-%d %H:%M:%S", 1790000000), "createdUtc → 本地墙钟")
Assert.eq(web.color, "blue", "槽位 2 → blue")
Assert.eq(web.drawer, "lighten")
Assert.eq(web.kavita_comment, remote_anns[1].comment)
Assert.eq(web.kavita_comment_html, "<p>记一笔</p>")
Assert.eq(web.kavita_slot, 2)
Assert.eq(web.kavita_spoiler, true)
Assert.eq(web.kavita_modified, "2026-10-04T05:06:07.890")
Assert.eq(web.kavita_xpath, "//body/p[1]")
Assert.eq(web.kavita_ending_xpath, "//body/p[1]")
-- spine 提示必须落库：开书定位只按 pageNumber（+1）挑 DocFragment，丢了它多 spine epub 全定位失败。
Assert.eq(web.pageNumber, 17, "DTO pageNumber 原样进 payload（0-based spine 提示）")
Assert.is_nil(web.pos0, "pull 不写坐标")
Assert.is_nil(web.pos1)
Assert.is_nil(web.page, "page 是定位阶段产物")
Assert.is_nil(web.pageno)
Assert.is_nil(web.chapter_idx, "整本桶")

local bare = pulled[2]
-- KOReader 的 getBookmarkType 用 `if bookmark.note then return "note"`：Lua 里 "" 为真，
-- 默认 bookmarks_items_text_type = "note" 就会把空备注写成「高亮与笔记」列表里的空行。
Assert.is_nil(bare.note, "空备注落 nil（不是空串），否则被当成 note 类型渲染空行")
Assert.is_nil(bare.kavita_note, "基线与 note 同源：空备注也是 nil（sameNote(nil, \"\") 仍判等）")
Assert.eq(bare.color, "yellow", "槽位越界回落 yellow")
Assert.eq(bare.pageNumber, 0, "DTO 缺 pageNumber 回落 0（只会试前两个 DocFragment）")

-- 清洗（保存快照前的白名单）不能把空备注的 nil 变回空串。
local cleaned_bare = source:cleanAnnotations(pulled, 10)
Assert.is_nil(cleaned_bare[2].note, "cleanAnnotations 后仍为 nil")
Assert.is_nil(cleaned_bare[2].kavita_note)
Assert.eq(cleaned_bare[1].note, "记一笔", "非空备注不受影响")

-- createdUtc 解析不出（Kavita 的 0001 占位）就用当前时间，仍然要落库。
routes["GET /api/Annotation/all"] = json({ {
    id = 504, ownerUserId = 5, xPath = "//body/p[4]", endingXPath = "//body/p[4]",
    selectedText = "无时间", comment = "", selectedSlotIndex = 0, createdUtc = "0001-01-01T00:00:00",
} })
local fallback = run("pullNotesAsync", volume)
Assert.eq(#fallback, 1)
local wall = fallback[1].datetime
local wy, wmo, wd, wh, wmi, ws = wall:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")
Assert.not_nil(wy, "datetime 必须是可读墙钟：YYYY-MM-DD HH:MM:SS")
Assert.is_true(math.abs(os.time({ year = tonumber(wy), month = tonumber(wmo), day = tonumber(wd),
    hour = tonumber(wh), min = tonumber(wmi), sec = tonumber(ws) }) - os.time()) <= 2,
    "解析失败回退当前时间")

-- 同章重复拉取幂等：payload 逐字段稳定（owner 已缓存，不再请求 /Users/me）。
routes["GET /api/Annotation/all"] = function(opts)
    ann_calls[#ann_calls + 1] = opts
    return json(remote_anns)
end
local function flatten(list)
    local out = {}
    for _idx, item in ipairs(list) do
        local keys = {}
        for key in pairs(item) do keys[#keys + 1] = key end
        table.sort(keys)
        local parts = {}
        for _j, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(item[key]) end
        out[#out + 1] = table.concat(parts, "&")
    end
    return table.concat(out, "||")
end
ann_calls = {}
local again = run("pullNotesAsync", volume)
Assert.eq(#ann_calls, 1, "owner 已缓存，不再请求 /Users/me")
Assert.eq(flatten(again), flatten(pulled), "重复拉取 payload 稳定")

-- 空文本的远端条目画不出来，但它的 id 必须进远端全量集合（spec §7 unlocated / §9.2）：
-- 丢在 annotationPayload 里，mergeAnnotations 就看不到这个 id，会把本地带该 id 的那条当成
-- 「远端已删」抹掉（反之远端还在，本地却消失）。
routes["GET /api/Annotation/all"] = json({ {
    id = 7, ownerUserId = 5, chapterId = 2002,
    xPath = "//body/p[7]", endingXPath = "//body/p[7]",
    selectedText = "   ", comment = "", selectedSlotIndex = 0,
    createdUtc = "2026-10-03T05:00:00",
} })
local blank_pulled = run("pullNotesAsync", volume)
Assert.eq(#blank_pulled, 1, "有 id 就保留占位（只有没 id 才真丢）")
Assert.eq(tonumber(blank_pulled[1].kavita_id), 7)
Assert.is_true(blank_pulled[1].kavita_unlocated, "空文本定位不出来：标记未定位")
Assert.is_nil(blank_pulled[1].drawer, "未定位占位不画、不进列表")
local local_seven = { datetime = "d7", page = "/body/p[7].0", pos0 = "/body/p[7].0",
    pos1 = "/body/p[7].5", drawer = "lighten", text = "本地定位过", kavita_id = 7 }
local merged_seven, dropped_seven = source:mergeAnnotations(blank_pulled, { local_seven }, nil, false)
Assert.eq(dropped_seven, 0, "空文本的远端条目仍占 id：本地那条不算远端已删")
Assert.eq(#merged_seven, 1, "远端不画，本地那份保留")
Assert.eq(merged_seven[1], local_seven)
-- 恢复后续用例用的三条 fixture。
routes["GET /api/Annotation/all"] = function(opts)
    ann_calls[#ann_calls + 1] = opts
    return json(remote_anns)
end

-- 取不到当前用户（/api/Users/me 不可用）→ 不过滤 + 记日志，不能因此不落库。
routes["GET /api/Users/me"] = { code = 404, body = "" }
local fresh = require("moonsource_kavita.source").new()
local warned = {}
local log = require("utils.log")
local real_warn = log.warn
log.warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
local unfiltered, ferr
fresh:pullNotesAsync(volume, function(a, e) unfiltered, ferr = a, e end)
Stubs.flush()
log.warn = real_warn
Assert.is_nil(ferr)
Assert.eq(#unfiltered, 3, "拿不到 owner 就不做属主过滤")
Assert.is_true(#warned >= 1, "降级要留一条日志")

-- GET 失败 → cb(nil, err)；核心拿到 nil 直接收尾（note.lua 的 finish(nil, err)），不会写桶，
-- 本地快照（含 sync_status=0 的脏行）保持原样。脏行保护在 NoteDB.upsertRemote
-- （`WHERE notes.sync_status=1`）与 note_sync_spec 里已覆盖，源侧不碰 notes 表。
routes["GET /api/Annotation/all"] = { code = 500, body = "" }
local fail_list, fail_err = run("pullNotesAsync", volume)
Assert.is_nil(fail_list)
Assert.matches(fail_err, "500")
routes["GET /api/Annotation/all"] = nil

-- 非 epub（PDF / 漫画）没有 Kavita 注解：空数组 + authoritative=false，一个请求都不发。
local before_pull = #calls
local none_pulled, none_err, none_meta = run("pullNotesAsync", pdf)
Assert.eq(#none_pulled, 0)
Assert.is_nil(none_err)
Assert.is_false(none_meta.authoritative)
Assert.eq(#calls, before_pull, "非 epub 零请求")

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

-- 漫画 cbz 用内置阅读器时进度同样上报：页级 0-based，读完发 pages（Kavita 据此标已读）。
sent = nil
local cbz = { source_id = "ext.kavita", stable_id = "60:6000" }
Assert.is_true(run("putProgressAsync", cbz, { fraction = 0.1, page = 4, total_pages = 30 }))
Assert.eq(sent.pageNum, 3, "cbz 页码 1-based → Kavita 0-based")
Assert.eq(sent.chapterId, 6000)
Assert.eq(sent.volumeId, 600)
Assert.eq(sent.libraryId, 3)
Assert.eq(sent.seriesId, 60)
Assert.is_nil(sent.bookScrollId, "非 epub 不带锚点")
run("putProgressAsync", cbz, { fraction = 1, page = 30, total_pages = 30 })
Assert.eq(sent.pageNum, 30, "读完发 pages")
run("putProgressAsync", cbz, { fraction = 0, page = 1, total_pages = 30 })
Assert.eq(sent.pageNum, 0, "第一页是 0（Kavita 页号 0-based）")
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
    local function findBook(rows, record_type, stable_id, start_time)
        for _idx, row in ipairs(rows) do
            if row.record_type == record_type and row.stable_id == stable_id
                and (not start_time or row.start_time == start_time) then return row end
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
        return json({
            { seriesId = 8661, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 12763, durationSeconds = 120, pagesRead = 0 } } },
            -- 云端读过、本机没有书行的卷：同一次同步的拉取照常物化补身份行（12 号票语义）。
            { seriesId = 10560, localDate = "2026-10-10T00:00:00",
                chapters = { { chapterId = 16493, durationSeconds = 60, pagesRead = 0 } } },
        }, { Pagination = pagination_header(1, 1) })
    end
    books["10560"] = { title = "镖人", authors = "丰" }
    remembered = {}

    local result = run("syncStatsAsync", nil)
    Assert.eq(marked[1], 21, "先本地确认本地待同步行")
    Assert.eq(replaced.source_id, "ext.kavita")
    local pulled_8661 = false
    for _idx, row in ipairs(replaced.rows) do
        if row.stable_id == "8661" then pulled_8661 = true end
    end
    Assert.is_true(pulled_8661, "拉取的行按云端快照入库")
    Assert.not_nil(replaced.replace, "替换指令一并交给核心")
    Assert.eq(events[1], "mark", "先推后拉：确认落在拉取之前")
    Assert.eq(events[#events], "replace", "最后是落库")
    Assert.eq(result.pushed, 1)
    Assert.eq(result.pulled, #replaced.rows)
    Assert.eq(remembered["10560:16493"] and remembered["10560:16493"].title, "镖人 · 一",
        "物化标题取状态文件里的持久化卷名")

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

-- 定位：pull 只落数据，开书时按 DocumentFragment 滑窗把 cloud 划线变成 crengine xpointer。
-- 假文档只实现定位用到的四个接口，语义按真机：`text()[k]` 逐个枚举、偏移按 codepoint 计。
do
    local function cp_len(s)
        local n = 0
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
        return n
    end

    local function cp_sub(s, from, to)
        local function byte_pos(count)
            local seen, i = 0, 1
            while seen < count and i <= #s do
                local b = s:byte(i)
                i = i + (b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4)
                seen = seen + 1
            end
            return i - 1
        end
        return s:sub(byte_pos(from - 1) + 1, byte_pos(to))
    end

    ---@param fragments table[] 每项是一页（DocFragment）的段落列表；段落是字符串或文本节点数组。
    ---@param file string|nil
    local function fakeDocument(fragments, file)
        local elements, nodes, pages = {}, {}, {}
        local order, fragment_text, node_offset = {}, {}, {}
        for f, paragraphs in ipairs(fragments) do
            local prefix = "/body/DocFragment[" .. f .. "]/body"
            order[f] = order[f] or {}
            for p, item in ipairs(paragraphs) do
                local elem = prefix .. "/p[" .. p .. "]"
                local texts = type(item) == "table" and item or { item }
                elements[elem] = table.concat(texts)
                for k, text in ipairs(texts) do
                    local path = elem .. "/text()[" .. k .. "]"
                    nodes[path] = text
                    order[f][#order[f] + 1] = path
                end
                pages[elem] = f * 10
            end
        end
        for f, paths in pairs(order) do
            local acc, offsets, parts = 0, {}, {}
            for _idx, path in ipairs(paths) do
                offsets[path] = acc
                acc = acc + cp_len(nodes[path])
                parts[#parts + 1] = nodes[path]
            end
            fragment_text[f] = table.concat(parts)
            node_offset[f] = offsets
        end

        local document = { file = file }
        function document:getTextFromXPointer(xp)
            local path = xp:gsub("%.%d+$", "")
            return nodes[path] or elements[path]
        end
        function document:isXPointerInDocument(xp)
            local path, off = xp:match("^(.*)%.(%d+)$")
            path = path or xp
            local text = nodes[path]
            if text then
                return off == nil or tonumber(off) <= cp_len(text)
            end
            return off == nil and elements[path] ~= nil
        end
        function document:getNormalizedXPointer(xp)
            return self:isXPointerInDocument(xp) and xp or false
        end
        -- 真机语义：pos1 是「选区后第一个字符」的偏移（不含），跨文本节点时按片段拼接。
        function document:getTextFromXPointers(pos0, pos1)
            local path0, off0 = pos0:match("^(.*)%.(%d+)$")
            local path1, off1 = pos1:match("^(.*)%.(%d+)$")
            if not path0 or not path1 then return nil end
            local f = tonumber(path0:match("DocFragment%[(%d+)%]"))
            if not f or not node_offset[f] or not node_offset[f][path0] or not node_offset[f][path1] then
                return nil
            end
            return cp_sub(fragment_text[f], node_offset[f][path0] + tonumber(off0) + 1,
                node_offset[f][path1] + tonumber(off1))
        end
        function document:getPageFromXPointer(xp)
            local elem = xp:match("^(.*)/text%(%)%[%d+%]%.%d+$")
            return pages[elem] or pages[xp] or 1
        end
        return document
    end

    os.execute("mkdir -p '" .. WORK .. "'")
    local book_path = WORK .. "/15-localize.epub"
    local fh = assert(io.open(book_path, "wb"))
    fh:write("PK\3\4epub")
    fh:close()

    local document = fakeDocument({
        {
            "春眠不觉晓，处处闻啼鸟。",
            "夜来风雨声，花落知多少。",
            { "春眠", "不觉晓" },
            { "第一段。", "第二段在同一 p 里。" },
            "去空白\194\160重试",
        },
        {
            "另一个 DocFragment 的正文。",
            "滑窗命中的句子。",
        },
        -- 多 spine 书（本票的真实形态）：第 5 个片段里这句只在 pageNumber = 4 的提示下才找得到。
        { "第三个片段的噪音。" },
        { "第四个片段的噪音。" },
        { "第五个片段里才有的一句。", "第五个片段的第二段。" },
    }, book_path)

    local anns = {
        {   -- 普通命中：段内偏移按 codepoint 算，page 与 reader 一致填 pos0 字符串。
            kavita_id = 601, datetime = "2026-10-01 00:00:00", text = "处处闻啼鸟", note = "好诗",
            kavita_note = "好诗", kavita_xpath = "//body/p[1]", kavita_ending_xpath = "//body/p[1]",
            pageNumber = 0,
        },
        {   -- 多文本节点：Kavita 的 text() 下标只当提示，按 crengine 的节点枚举重新映射。
            kavita_id = 602, text = "不觉晓", kavita_xpath = "//body/p[3]",
            kavita_ending_xpath = "//body/p[3]", pageNumber = 0,
        },
        {   -- pageNumber 差一位（旧推送窗口）：spine 提示失败，靠 +1 滑窗命中。
            kavita_id = 603, text = "滑窗命中的句子", kavita_xpath = "//body/p[2]",
            kavita_ending_xpath = "//body/p[2]", pageNumber = 0,
        },
        {   -- 跨段：起点取贴段尾的最长前缀，终点取贴段首的最长后缀。
            kavita_id = 604, text = "啼鸟。夜来", kavita_xpath = "//body/p[1]",
            kavita_ending_xpath = "//body/p[2]", pageNumber = 0,
        },
        {   -- 元素下标失配（Kavita 的 p 数与 crengine 不同）：同片段同级回扫。
            kavita_id = 605, text = "第二段在同一 p 里。", kavita_xpath = "//body/p[9]",
            kavita_ending_xpath = "//body/p[9]", pageNumber = 0,
        },
        {   -- 单条失败不能拖累同书其它条：标 unlocated，不写占位坐标。
            kavita_id = 606, text = "这句话不在书里", kavita_xpath = "//body/p[2]",
            kavita_ending_xpath = "//body/p[2]", pageNumber = 0,
        },
        {   -- 同一 kavita_id 已有通过校验的坐标：直接复用，避免每次开书重算。
            kavita_id = 607, text = "这句也找不到", kavita_xpath = "//body/p[1]",
            kavita_ending_xpath = "//body/p[1]", pageNumber = 0,
        },
        {   -- 旧坐标已失效（偏移越界）：不复用，重算失败照常标 unlocated。
            kavita_id = 608, text = "哪里都没有", kavita_xpath = "//body/p[1]",
            kavita_ending_xpath = "//body/p[1]", pageNumber = 0,
        },
        {   -- 空白折叠差异（crengine 保留 NBSP，Kavita 存普通空格）：去空白重试后回算偏移。
            kavita_id = 609, text = "去空白 重试", kavita_xpath = "//body/p[5]",
            kavita_ending_xpath = "//body/p[5]", pageNumber = 0,
        },
    }
    local current = {
        { kavita_id = 607, pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].0",
            pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].2", page = "旧", pageno = 9 },
        { kavita_id = 608, pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].999",
            pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].1000", page = "越界" },
    }

    local localized = source:localizeAnnotations(document, anns, book_path, current)
    Assert.len(localized, #anns, "返回全量：定位失败的也在列表里")
    Assert.eq(localized[1].kavita_id, 601)
    Assert.eq(localized[1].pos0, "/body/DocFragment[1]/body/p[1]/text()[1].6")
    Assert.eq(localized[1].pos1, "/body/DocFragment[1]/body/p[1]/text()[1].11")
    Assert.eq(localized[1].page, localized[1].pos0, "page 填 pos0 字符串，不能填数字")
    Assert.eq(localized[1].pageno, 10)
    Assert.eq(localized[1].note, "好诗", "定位只补坐标，不动 pull 落的字段")
    Assert.eq(localized[1].kavita_note, "好诗")
    Assert.is_nil(localized[1].kavita_unlocated)

    Assert.eq(localized[2].pos0, "/body/DocFragment[1]/body/p[3]/text()[2].0",
        "span 内文本按 crengine 的 text()[k] 重新编号")
    Assert.eq(localized[2].pos1, "/body/DocFragment[1]/body/p[3]/text()[2].3")

    Assert.eq(localized[3].pos0, "/body/DocFragment[2]/body/p[2]/text()[1].0", "pageNumber 只当提示，+1 滑窗命中")
    Assert.eq(localized[3].pageno, 20)

    Assert.eq(localized[4].pos0, "/body/DocFragment[1]/body/p[1]/text()[1].9", "跨段起点贴段尾")
    Assert.eq(localized[4].pos1, "/body/DocFragment[1]/body/p[2]/text()[1].2", "跨段终点贴段首")

    Assert.eq(localized[5].pos0, "/body/DocFragment[1]/body/p[4]/text()[2].0", "p[9] 不存在时回扫同级")

    Assert.is_true(localized[6].kavita_unlocated, "文本匹配不到就标未定位")
    Assert.is_nil(localized[6].pos0, "未定位不写占位坐标")
    Assert.is_nil(localized[6].pos1)
    Assert.is_nil(localized[6].page)

    Assert.eq(localized[7].pos0, "/body/DocFragment[1]/body/p[1]/text()[1].0", "复用 current 的有效坐标")
    Assert.eq(localized[7].pos1, "/body/DocFragment[1]/body/p[1]/text()[1].2")
    Assert.is_nil(localized[7].kavita_unlocated)

    Assert.is_true(localized[8].kavita_unlocated, "旧坐标越界不能复用")
    Assert.is_nil(localized[8].pos0)

    Assert.eq(localized[9].pos0, "/body/DocFragment[1]/body/p[5]/text()[1].0", "NBSP 与普通空格差异靠去空白重试")
    Assert.eq(localized[9].pos1, "/body/DocFragment[1]/body/p[5]/text()[1].6")
    Assert.is_nil(localized[9].kavita_unlocated)

    -- 本票的链路回归（pull → cleanAnnotations → localize）：三国演义这种多 spine epub 的注解在
    -- pageNumber 17/23/24（0-based），没有这个提示就只试 DocFragment[1]/[2]，
    -- 第 3 个片段之后全部 text-not-found → kavita_unlocated，一条都不画。
    routes["GET /api/Annotation/all"] = json({ {
        id = 701, ownerUserId = 5, chapterId = 2002,
        xPath = "//body/p[1]", endingXPath = "//body/p[1]",
        selectedText = "第五个片段里才有的一句",
        comment = "", commentHtml = "", commentPlainText = "",
        selectedSlotIndex = 0, createdUtc = "2026-10-03T05:00:00",
        pageNumber = 4,
    } })
    local chain_pulled = run("pullNotesAsync", volume)
    Assert.eq(chain_pulled[1].pageNumber, 4, "pull 保留 DTO 的 spine 提示")
    local chain_clean = source:cleanAnnotations(chain_pulled, 0)
    Assert.eq(chain_clean[1].pageNumber, 4, "cleanAnnotations 不能把提示洗掉")
    local chain_located = source:localizeAnnotations(document, chain_clean, book_path, nil)
    Assert.eq(chain_located[1].pos0, "/body/DocFragment[5]/body/p[1]/text()[1].0",
        "pageNumber = 4 → 先试 DocFragment[5] 命中")
    Assert.eq(chain_located[1].pos1, "/body/DocFragment[5]/body/p[1]/text()[1].11")
    Assert.is_nil(chain_located[1].kavita_unlocated)

    -- 回归锁：同一份条目抹掉 pageNumber → 只试前两个片段 → 定位失败（真实 bug 的形态）。
    local no_hint = {}
    for key, value in pairs(chain_clean[1]) do no_hint[key] = value end
    no_hint.pageNumber = nil
    local orphan = source:localizeAnnotations(document, { no_hint }, book_path, nil)
    Assert.is_true(orphan[1].kavita_unlocated, "没有 spine 提示时第 3 个片段之后的文本定位不到")
    Assert.is_nil(orphan[1].pos0)
    Assert.is_nil(orphan[1].page)

    -- 无文档 / html_path 缺失 / 文件不存在 / 文档不是这本书 → nil（core 据此放弃应用，不覆盖 doc_settings）。
    Assert.is_nil(source:localizeAnnotations(nil, anns, book_path, current))
    Assert.is_nil(source:localizeAnnotations(document, anns, nil, current))
    Assert.is_nil(source:localizeAnnotations(document, anns, "", current))
    Assert.is_nil(source:localizeAnnotations(document, anns, WORK .. "/missing.epub", current))
    local other = fakeDocument({ { "别的书" } }, WORK .. "/other.epub")
    Assert.is_nil(source:localizeAnnotations(other, anns, book_path, current), "document.file 与 html_path 不一致")
end

os.execute("rm -rf '" .. WORK .. "'")
