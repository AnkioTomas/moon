--[[-- features.subscribe.source：订阅即按章书（目录 = 条目、目录变了作废章节、正文成整篇文档、翻到即已读、不记进度）。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local items, read, scopes, extra = {}, {}, {}, {}
package.loaded["features.subscribe.db"] = {
    scopeOf = function(id)
        if id:match("^%d+$") then return { feed = tonumber(id), mode = "all", q = "" } end
        return scopes[id]
    end,
    stream = function(spec, page, size)
        Assert.eq(page, 1)
        Assert.eq(size, -1, "目录取全部条目")
        local out = {}
        for i, item in ipairs(items) do
            out[i] = { feed_id = item.feed_id or spec.feed or 3, guid = item.guid, title = item.title, link = item.link,
                time = item.time or 0 }
        end
        return out
    end,
    item = function(feed_id, guid) return extra[feed_id .. ":" .. guid] end,
    feed = function(id) return (id == 3 or id == 4) and { id = id, kind = "rss", title = "源<名" } or nil end,
    markRead = function(id, guid) read[#read + 1] = id .. ":" .. guid end,
}
local tocs, dropped = {}, {}
package.loaded["source.toc"] = {
    read = function(_s, id, stale) Assert.is_true(stale, "章号基线必须不看 TTL"); return tocs[id] end,
    put = function(_s, id, list) tocs[id] = list; return true end,
}
package.loaded["book.chapters_db"] = { deleteUnder = function(dir) dropped[#dropped + 1] = dir end }
local remaps = {}
local noted = {}
package.loaded["book.note_db"] = {
    remapChapters = function(_s, id, map) remaps[#remaps + 1] = { id, map } end,
    all = function() return noted end,
}
local root = require("support.config").dir() .. "/subscribe_source_spec"
package.loaded["utils.paths"] = { bookWorkDir = function(id, src) return root .. "/" .. src .. "/" .. id end }
package.loaded["features.subscribe"] = {
    dir = function(id) return root .. "/subscribe/" .. id end,
    articlePath = function(id, guid) return root .. "/subscribe/" .. id .. "/" .. guid .. ".html" end,
    content = function(feed, item, cb)
        Assert.is_true(feed.id == 3 or feed.id == 4)
        cb("<h1>" .. item.title .. "</h1><p>正文</p><img src=\"images/a.jpg\"/>")
    end,
}
local snap -- 阅读器当前会话（nil = 没开书）
package.loaded["reader.session"] = { current = function() return snap end }
package.loaded["features.subscribe.source"] = nil
local M = require("features.subscribe.source")

Assert.eq(M.meta().type, "chapter")
local src = M.new()
Assert.is_true(src.ephemeral, "不记进度 / 统计")
Assert.is_nil(src.getProgressAsync, "没有云端进度")
local book = M.book("3", "源")
Assert.eq(book.source_id, "subscribe")
Assert.eq(book.stable_id, "3")

-- 目录：同订阅页顺序，uid = guid；第一次不作废
local identity = { source_id = "subscribe", stable_id = "3" }
items = { { guid = "b", title = "新", link = "https://x/b" }, { guid = "a", title = "" } }
local toc
src:loadTocAsync(identity, function(t) toc = t end)
Stubs.flush()
Assert.eq(#toc, 2)
Assert.eq(toc[1].uid, "b")
Assert.eq(toc[2].title, "无标题")
Assert.eq(#dropped, 0)
-- 目录没变不作废；新增条目让章号错位，作废章节登记
src:loadTocAsync(identity, function() end)
Stubs.flush()
Assert.eq(#dropped, 0)
-- 新增条目让章号错位：章节文件、双语章、边车和注解按 guid 挪到新章号，淘汰的删掉。
local dir = root .. "/subscribe/3"
os.execute("rm -rf '" .. root .. "' && mkdir -p '" .. dir .. "/1.sdr' '" .. dir .. "/2.sdr' '" .. dir .. "/articles'")
local function touch(name, body)
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(body)
    f:close()
end
local function slurp(name)
    local f = io.open(dir .. "/" .. name, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end
touch("1.html", "b")
touch("2.html", "a")
touch("2.bi-edge-en.html", "a-bi")
touch("1.sdr/metadata.html.lua", "notes-b")
touch("2.sdr/metadata.html.lua", "notes-a")
touch("articles/x.html", "keep")
items = { { guid = "c", title = "更新" }, { guid = "b", title = "新" } } -- a 被淘汰、c 新增
src:loadTocAsync(identity, function(t) toc = t end)
Stubs.flush()
Assert.eq(toc[1].uid, "c")
Assert.eq(remaps[1][1], "3")
Assert.eq(remaps[1][2][1], 2, "b：1 → 2")
Assert.is_nil(remaps[1][2][2], "a 淘汰")
Assert.eq(slurp("2.html"), "b", "章节文件跟文章走")
Assert.eq(slurp("2.sdr/metadata.html.lua"), "notes-b", "KOReader 边车跟文章走")
Assert.is_nil(slurp("1.html"), "新文章的章号上没有旧文件")
Assert.is_nil(slurp("1.sdr/metadata.html.lua"))
Assert.is_nil(slurp("2.bi-edge-en.html"), "淘汰文章的双语章删掉")
Assert.eq(slurp("articles/x.html"), "keep")
Assert.eq(dropped[1], dir, "章节登记撤掉，开章重登")
os.execute("rm -rf '" .. root .. "'")
-- 空订阅报错
local saved = items
items = {}
local err
src:loadTocAsync({ source_id = "subscribe", stable_id = "9" }, function(t, e) err = { t, e } end)
Stubs.flush()
Assert.is_nil(err[1])
Assert.eq(err[2], "订阅里还没有文章")
items = saved

-- 翻到哪章哪篇已读
src:onEvent("chapter_changed", { identity = { stable_id = "3", chapter_idx = 2 } })
Assert.eq(read[1], "3:b")
src:onEvent("page_changed", { identity = { stable_id = "3", chapter_idx = 1 } })
Assert.eq(#read, 1)

-- 打开前先同步目录：本地快开不读目录，刷新后顺序变了也得先把章节挪到新章号再开。
local opened
package.loaded["source.chapter"] = {
    openWithUi = function(_s, ident) opened = tocs[ident.stable_id] end,
}
items = { { guid = "d", title = "最新" }, { guid = "c", title = "更新" }, { guid = "b", title = "新" } }
src:openBookAsync({ source_id = "subscribe", stable_id = "3", book = book }, { chapter_idx = 3 }, function() end)
Assert.eq(opened[1].uid, "d", "开书时目录已是订阅库的新顺序")
Assert.eq(opened[3].uid, "b")

-- 阅读中（这本订阅正开着）目录变了：不重排章号、沿用旧目录；打开时（force）才挪。
do
    remaps = {}
    snap = { identity = { source_id = "subscribe", stable_id = "3" } }
    local before = tocs["3"]
    items = { { guid = "e", title = "又一篇" }, { guid = "d", title = "最新" }, { guid = "c", title = "更新" }, { guid = "b", title = "新" } }
    local got
    src:refreshTocAsync({ source_id = "subscribe", stable_id = "3" }, function(t) got = t end)
    Stubs.flush()
    Assert.eq(got, before, "阅读中沿用旧目录")
    Assert.eq(tocs["3"], before)
    Assert.eq(#remaps, 0, "阅读中不挪章号")
    snap = { identity = { source_id = "subscribe", stable_id = "4" } }
    src:refreshTocAsync({ source_id = "subscribe", stable_id = "3" }, function(t) got = t end)
    Stubs.flush()
    Assert.eq(got[1].uid, "e", "开着的是别的书：照常同步")
    snap = nil
end

-- 改名失败的那份直接删（不留在旧章号上错位）；上次中断留下的 .mv- 临时名清掉。
do
    os.execute("rm -rf '" .. root .. "' && mkdir -p '" .. dir .. "'")
    touch("1.html", "e")
    touch("2.html", "d")
    touch(".mv-7.html", "stale")
    local real = os.rename
    os.rename = function(from, to)
        if from:match("/1%.html$") then return nil, "EACCES" end
        return real(from, to)
    end
    items = { { guid = "f", title = "六" }, { guid = "e", title = "又一篇" }, { guid = "d", title = "最新" } }
    src:loadTocAsync({ source_id = "subscribe", stable_id = "3" }, function() end)
    Stubs.flush()
    os.rename = real
    Assert.is_nil(slurp("1.html"), "改名失败的删掉")
    Assert.is_nil(slurp("2.html"), "e 的位置没有错文件")
    Assert.eq(slurp("3.html"), "d", "d：2 → 3")
    Assert.is_nil(slurp(".mv-7.html"), "残留临时名清掉")
    Assert.is_nil(slurp(".mv-2.html"))
    os.execute("rm -rf '" .. root .. "'")
end

-- 已缓存文章的二、三级标题成章内小节（目录没变也更新目录缓存）；没缓存的没有小节
do
    os.execute("mkdir -p '" .. dir .. "/articles'")
    local f = assert(io.open(dir .. "/articles/" .. require("ffi/sha2").md5("f") .. ".html", "wb"))
    f:write('<h1>六</h1><h2 id="mh1">一节</h2><h3 id="mh2">小节</h3>')
    f:close()
    local list
    src:loadTocAsync(identity, function(t) list = t end)
    Stubs.flush()
    Assert.eq(#list[1].anchors, 2)
    Assert.eq(list[1].anchors[2].depth, 3)
    Assert.eq(list[1].anchors[2].id, "mh2")
    Assert.is_nil(list[2].anchors)
    Assert.eq(#tocs["3"][1].anchors, 2, "目录缓存跟着更新")
    os.execute("rm -rf '" .. root .. "'")
end


-- 筛选范围的书（stable_id 非订阅 id）：uid = 订阅 id:guid，跨源；正文、已读都按 uid 拆回 (源, guid)。
do
    scopes.sabc = { mode = "unread", q = "" }
    items = { { feed_id = 3, guid = "a", title = "甲", time = 30 }, { feed_id = 4, guid = "b:x", title = "乙", time = 20 } }
    local ident = { source_id = "subscribe", stable_id = "sabc" }
    local t = M.toc(ident)
    Assert.eq(t[1].uid, "3:a")
    Assert.eq(t[2].uid, "4:b:x", "guid 里带冒号照样拆得回")
    local payload
    ---@type { fetchContent: function }|nil
    local ops = nil
    package.loaded["source.chapter"] = { openWithUi = function(_s, _i, _b, _o, o) ops = o end }
    src:openBookAsync({ source_id = "subscribe", stable_id = "sabc", book = book }, {}, function() end)
    ops.fetchContent(ident, { idx = 2, uid = "4:b:x", title = "乙", link = "" }, function(p) payload = p end)
    Assert.matches(payload.document, "乙")
    Assert.matches(payload.document, 'src="%.%./4/images/a%.jpg"', "范围书的图指回订阅目录")
    src:onEvent("chapter_changed", { identity = { stable_id = "sabc", chapter_idx = 2 } })
    Assert.eq(read[#read], "4:b:x")

    -- 带注解的旧章退出了范围（读过了）：留在目录里并按时间归位，划线不丢。
    tocs.sabc = { { idx = 1, uid = "3:a" }, { idx = 2, uid = "3:gone" } }
    noted = { { chapter_idx = 2 } }
    extra["3:gone"] = { feed_id = 3, guid = "gone", title = "读过", link = "", time = 25 }
    t = M.toc(ident)
    Assert.eq(#t, 3)
    Assert.eq(t[2].uid, "3:gone", "按时间插回 a 与 b 之间")
    Assert.eq(t[3].idx, 3)
    noted = {}
end

-- 重新下载本章：文章缓存一并作废
do
    local dir = root .. "/subscribe/3"
    os.execute("mkdir -p " .. dir)
    local path = dir .. "/zz.html"
    io.open(path, "w"):close()
    src:dropChapterCache({ stable_id = "3", source_id = "subscribe" }, { uid = "zz", idx = 1, title = "" })
    Assert.is_nil(io.open(path, "r"), "文章缓存已删")
end
