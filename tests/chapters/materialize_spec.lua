--[[--
chapters materialize 离线用例：目录归一化 / start_idx 推算 / 预取目标选择

@module tests.chapters.materialize_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Fakes = require("support.chapter_fakes")
Stubs.install()
Stubs.reset()

-- 内存文件系统（同 ensure_spec 模式）：Html.write/isValid 全程不落真盘
local files = {}

local real_open = io.open
io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("w") then
        local buf = {}
        return {
            write = function(_, data) buf[#buf + 1] = data end,
            close = function()
                files[path] = table.concat(buf)
            end,
        }
    end
    if files[path] then
        local data = files[path]
        local pos = 1
        return {
            read = function(_, n)
                if n == "*a" then
                    local out = data:sub(pos)
                    pos = #data + 1
                    return out
                end
                local out = data:sub(pos, pos + (tonumber(n) or 1) - 1)
                pos = pos + #out
                return out ~= "" and out or nil
            end,
            close = function() end,
            seek = function() end,
        }
    end
    return real_open(path, mode)
end

local old_rename = os.rename
local old_remove = os.remove
os.rename = function(a, b)
    if files[a] then
        files[b] = files[a]
        files[a] = nil
        return true
    end
    return old_rename(a, b)
end
os.remove = function(path)
    files[path] = nil
    return true
end

Fakes.install()

-- ── toc 缓存 / 本地进度桩（目录缓存 + 本地优先用例用）──────
-- json：encode 只服务扁平表/数组（同 server_spec 写法），decode 用真解析器
local json_encode
do
    local function encode(v)
        local t = type(v)
        if t == "string" then
            return string.format("%q", v)
        elseif t == "number" or t == "boolean" then
            return tostring(v)
        elseif t == "table" then
            local parts = {}
            if #v > 0 then
                for i = 1, #v do
                    parts[#parts + 1] = encode(v[i])
                end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            for k, val in pairs(v) do
                if val ~= nil then
                    parts[#parts + 1] = encode(tostring(k)) .. ":" .. encode(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        error("json stub: unsupported " .. t)
    end
    json_encode = encode
    package.preload["json"] = function()
        return { encode = encode, decode = require("support.json_stub").decode }
    end
end

local toc_store = {} -- "sid\0stid" → { payload=, fetched_at= }
local toc_get_calls = {}
local toc_upserts = {}
package.preload["utils.db.toc"] = function()
    return {
        get = function(source_id, stable_id, max_age)
            toc_get_calls[#toc_get_calls + 1] = {
                source_id = source_id, stable_id = stable_id, max_age = max_age,
            }
            local row = toc_store[source_id .. "\0" .. stable_id]
            if not row then
                return nil
            end
            return row.payload, row.fetched_at
        end,
        upsert = function(source_id, stable_id, payload)
            toc_upserts[#toc_upserts + 1] = {
                source_id = source_id, stable_id = stable_id, payload = payload,
            }
            return true
        end,
        delete = function() return true end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts)
            worker(nil)
            if opts and opts.on_done then
                opts.on_done(nil)
            end
        end,
        clear = function() end,
    }
end
local progress_rows = {} -- "sid\0stid" → pending_progress 行
package.preload["utils.db.progress"] = function()
    return {
        get = function(source_id, stable_id)
            return progress_rows[source_id .. "\0" .. stable_id]
        end,
    }
end
local open_rows = {} -- "sid\0stid" → opens 行
package.preload["utils.db.open"] = function()
    return {
        get = function(source_id, stable_id)
            return open_rows[source_id .. "\0" .. stable_id]
        end,
    }
end

for _, name in ipairs({
    "chapters.materialize", "chapters.html", "chapters.session",
    "book.store", "types.book_progress",
}) do
    package.loaded[name] = nil
end

local Materialize = require("chapters.materialize")
local Session = require("chapters.session")
local UIManager = require("ui/uimanager")

-- ---------------------------------------------------------------------------
-- loadTocAsync：目录归一化
-- ---------------------------------------------------------------------------

-- 源不支持 getTocAsync：nextTick 回失败
do
    local done
    Materialize.loadTocAsync({}, {}, function(ok, chapters, err)
        done = { ok, chapters, err }
    end)
    Stubs.flush()
    Assert.eq(done[1], false)
    Assert.is_nil(done[2])
    Assert.matches(done[3], "数据源不支持目录")
end

-- 拉取失败：err 透传
do
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb(nil, "网络错误")
        end,
    }
    local done
    Materialize.loadTocAsync(source, {}, function(ok, chapters, err)
        done = { ok, chapters, err }
    end)
    Assert.eq(done[1], false)
    Assert.is_nil(done[2])
    Assert.eq(done[3], "网络错误")
end

-- 空目录与非 table 目录都拒绝
do
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb({})
        end,
    }
    local done
    Materialize.loadTocAsync(source, {}, function(ok, chapters, err)
        done = { ok, chapters, err }
    end)
    Assert.eq(done[1], false)
    Assert.matches(done[3], "目录为空")

    source.getTocAsync = function(_, _ref, cb)
        cb("不是table")
    end
    done = nil
    Materialize.loadTocAsync(source, {}, function(ok, _chapters, err)
        done = { ok, err }
    end)
    Assert.eq(done[1], false)
    Assert.matches(done[2], "目录为空")
end

-- 归一化：idx 字符串转数字、缺 idx 用位置兜底、空 title 用位置串兜底、source_idx/uid 透传
do
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb({
                { idx = "5", title = "第五章", source_idx = "s5", uid = "u5" },
                { title = "" },
                { idx = 7 },
            })
        end,
    }
    local done
    Materialize.loadTocAsync(source, {}, function(ok, chapters)
        done = { ok, chapters }
    end)
    Assert.eq(done[1], true)
    Assert.len(done[2], 3)
    Assert.eq(done[2][1].idx, 5)
    Assert.eq(done[2][1].title, "第五章")
    Assert.eq(done[2][1].source_idx, "s5")
    Assert.eq(done[2][1].uid, "u5")
    Assert.eq(done[2][2].idx, 2)
    Assert.eq(done[2][2].title, "2")
    Assert.eq(done[2][3].idx, 7)
    Assert.eq(done[2][3].title, "3")
end

-- ---------------------------------------------------------------------------
-- prepareOpenAsync：start_idx 推算
-- ---------------------------------------------------------------------------

local toc10 = {}
for i = 1, 10 do
    toc10[i] = { idx = i, title = "第" .. i .. "章" }
end

--- 造同步拉目录/进度的假源；pos 传 false 表示源不支持 getProgressAsync
local function makeSource(pos)
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb(toc10)
        end,
    }
    if pos ~= false then
        source.getProgressAsync = function(_, _ref, cb)
            cb(pos)
        end
    end
    return source
end

-- chapter_idx 优先于 fraction
do
    local book = { title = "b" }
    local done
    Materialize.prepareOpenAsync(makeSource({ chapter_idx = 3, fraction = 0.9 }), book, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 3)
    Assert.eq(done[2].book, book)
    Assert.len(done[2].toc, 10)
end

-- chapter_idx 是数字字符串也认
do
    local done
    Materialize.prepareOpenAsync(makeSource({ chapter_idx = "4" }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 4)
end

-- chapter_idx 越界：与 fraction 路径一样 clamp 到目录范围
do
    local done
    Materialize.prepareOpenAsync(makeSource({ chapter_idx = 99 }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 10)

    done = nil
    Materialize.prepareOpenAsync(makeSource({ chapter_idx = 0 }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 1)
end

-- 只有 fraction：按目录长度换算（floor(pct * n) + 1）
do
    local done
    Materialize.prepareOpenAsync(makeSource({ fraction = 0.5 }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 6)
end

-- fraction 换算越界：clamp 到末章
do
    local done
    Materialize.prepareOpenAsync(makeSource({ fraction = 1 }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 10)
end

-- fraction 为 0：不算越界，回第 1 章
do
    local done
    Materialize.prepareOpenAsync(makeSource({ fraction = 0 }), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 1)
end

-- 无进度可拉（pos=nil）与源不支持进度：都回第 1 章
do
    local done
    Materialize.prepareOpenAsync(makeSource(nil), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 1)

    done = nil
    Materialize.prepareOpenAsync(makeSource(false), {}, {}, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 1)
end

-- 目录为空：整体失败
do
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb({})
        end,
        getProgressAsync = function(_, _ref, cb)
            cb({ chapter_idx = 3 })
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, {}, function(ok, prep, err)
        done = { ok, prep, err }
    end)
    Assert.eq(done[1], false)
    Assert.is_nil(done[2])
    Assert.matches(done[3], "目录为空")
end

-- ---------------------------------------------------------------------------
-- loadTocAsync：online 源 toc 表缓存（6 小时 TTL）
-- ---------------------------------------------------------------------------

-- 缓存命中：不拉取，from_cache=true，目录内容来自缓存
do
    Assert.eq(Materialize.TOC_TTL, 6 * 60 * 60)
    toc_store["moon\0c-hit"] = {
        payload = json_encode({ { idx = 1, title = "c1" }, { idx = 2, title = "c2" } }),
        fetched_at = os.time(),
    }
    local fetched = 0
    local source = {
        type = "online",
        getTocAsync = function(_, _ref, cb)
            fetched = fetched + 1
            cb({ { idx = 9, title = "x" } })
        end,
    }
    local done
    Materialize.loadTocAsync(source, { source_id = "moon", stable_id = "c-hit" }, function(ok, chapters, err, from_cache)
        done = { ok, chapters, err, from_cache }
    end)
    Stubs.flush() -- 命中走 nextTick
    Assert.eq(done[1], true)
    Assert.eq(done[4], true)
    Assert.len(done[2], 2)
    Assert.eq(done[2][1].title, "c1")
    Assert.eq(done[2][2].idx, 2)
    Assert.eq(fetched, 0)
    Assert.eq(toc_get_calls[#toc_get_calls].max_age, Materialize.TOC_TTL)
end

-- 缓存 miss：拉取 + 归一化 + 落缓存（upsert 收到 JSON 串），from_cache=nil
do
    local base_upserts = #toc_upserts
    local source = {
        type = "online",
        getTocAsync = function(_, _ref, cb)
            cb({ { idx = "3", title = "三" }, { title = "" } })
        end,
    }
    local done
    Materialize.loadTocAsync(source, { source_id = "moon", stable_id = "c-miss" }, function(ok, chapters, err, from_cache)
        done = { ok, chapters, err, from_cache }
    end)
    Assert.eq(done[1], true)
    Assert.is_nil(done[4])
    Assert.len(done[2], 2)
    Assert.eq(done[2][1].idx, 3)
    Assert.eq(done[2][2].title, "2")
    Assert.eq(#toc_upserts, base_upserts + 1)
    local up = toc_upserts[#toc_upserts]
    Assert.eq(up.source_id, "moon")
    Assert.eq(up.stable_id, "c-miss")
    Assert.eq(type(up.payload), "string")
    local decoded = require("support.json_stub").decode(up.payload)
    Assert.len(decoded, 2)
    Assert.eq(decoded[1].idx, 3)
    Assert.eq(decoded[1].title, "三")
end

-- article(rss) 源：无论缓存有没有货都不查缓存
do
    toc_store["moon\0art"] = {
        payload = json_encode({ { idx = 1, title = "cached" } }),
        fetched_at = os.time(),
    }
    local base_get = #toc_get_calls
    local fetched = 0
    local source = {
        type = "article",
        getTocAsync = function(_, _ref, cb)
            fetched = fetched + 1
            cb({ { idx = 1, title = "fresh" } })
        end,
    }
    local done
    Materialize.loadTocAsync(source, { source_id = "moon", stable_id = "art" }, function(ok, chapters, err, from_cache)
        done = { ok, chapters, from_cache }
    end)
    Assert.eq(done[1], true)
    Assert.is_nil(done[3])
    Assert.eq(done[2][1].title, "fresh")
    Assert.eq(fetched, 1)
    Assert.eq(#toc_get_calls, base_get)
end

-- ---------------------------------------------------------------------------
-- prepareOpenAsync：起始章本地优先（pending → opens → 云端）
-- ---------------------------------------------------------------------------

-- pending_progress 有 chapter_idx：用之且不调云端
do
    progress_rows["moon\0lp"] = { chapter_idx = 7, fraction = 0.6 }
    local cloud_called = 0
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb(toc10)
        end,
        getProgressAsync = function(_, _ref, cb)
            cloud_called = cloud_called + 1
            cb({ chapter_idx = 2 })
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, { source_id = "moon", stable_id = "lp" }, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 7)
    Assert.eq(cloud_called, 0)
    progress_rows["moon\0lp"] = nil
end

-- pending 只有 fraction>0 也算本地进度：按比例换算
do
    progress_rows["moon\0lf"] = { fraction = 0.5 }
    local cloud_called = 0
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb(toc10)
        end,
        getProgressAsync = function(_, _ref, cb)
            cloud_called = cloud_called + 1
            cb({ chapter_idx = 2 })
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, { source_id = "moon", stable_id = "lf" }, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 6) -- floor(0.5*10)+1
    Assert.eq(cloud_called, 0)
    progress_rows["moon\0lf"] = nil
end

-- pending 无货 → opens.chapter_idx 兜底，仍不调云端
do
    open_rows["moon\0op"] = { chapter_idx = 4 }
    local cloud_called = 0
    local source = {
        getTocAsync = function(_, _ref, cb)
            cb(toc10)
        end,
        getProgressAsync = function(_, _ref, cb)
            cloud_called = cloud_called + 1
            cb({ chapter_idx = 2 })
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, { source_id = "moon", stable_id = "op" }, function(ok, prep)
        done = { ok, prep }
    end)
    Assert.eq(done[1], true)
    Assert.eq(done[2].start_idx, 4)
    Assert.eq(cloud_called, 0)
    open_rows["moon\0op"] = nil
end

-- ---------------------------------------------------------------------------
-- prepareOpenAsync：缓存目录偏旧守卫（进度指向章超出缓存目录 → 弃缓存重拉）
-- ---------------------------------------------------------------------------

-- 重拉成功：用新目录，start_idx 不再 clamp 到旧目录
do
    toc_store["moon\0stale"] = {
        payload = json_encode({ { idx = 1, title = "c1" }, { idx = 2, title = "c2" }, { idx = 3, title = "c3" } }),
        fetched_at = os.time(),
    }
    progress_rows["moon\0stale"] = { chapter_idx = 9 }
    local toc12 = {}
    for i = 1, 12 do
        toc12[i] = { idx = i, title = "n" .. i }
    end
    local fetched = 0
    local source = {
        type = "online",
        getTocAsync = function(_, _ref, cb)
            fetched = fetched + 1
            cb(toc12)
        end,
        getProgressAsync = function(_, _ref, cb)
            cb(nil)
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, { source_id = "moon", stable_id = "stale" }, function(ok, prep)
        done = { ok, prep }
    end)
    Stubs.flush() -- 首次命中缓存走 nextTick
    Assert.eq(done[1], true)
    Assert.eq(fetched, 1) -- 首次缓存命中没拉；偏旧守卫重拉一次
    Assert.len(done[2].toc, 12)
    Assert.eq(done[2].start_idx, 9)
    toc_store["moon\0stale"] = nil
    progress_rows["moon\0stale"] = nil
end

-- 重拉失败：退回旧缓存目录，start_idx clamp 到旧目录末章
do
    toc_store["moon\0stale2"] = {
        payload = json_encode({ { idx = 1, title = "c1" }, { idx = 2, title = "c2" }, { idx = 3, title = "c3" } }),
        fetched_at = os.time(),
    }
    progress_rows["moon\0stale2"] = { chapter_idx = 9 }
    local fetched = 0
    local source = {
        type = "online",
        getTocAsync = function(_, _ref, cb)
            fetched = fetched + 1
            cb(nil, "网络错误")
        end,
        getProgressAsync = function(_, _ref, cb)
            cb(nil)
        end,
    }
    local done
    Materialize.prepareOpenAsync(source, {}, { source_id = "moon", stable_id = "stale2" }, function(ok, prep)
        done = { ok, prep }
    end)
    Stubs.flush()
    Assert.eq(done[1], true)
    Assert.eq(fetched, 1)
    Assert.len(done[2].toc, 3)
    Assert.eq(done[2].start_idx, 3)
    toc_store["moon\0stale2"] = nil
    progress_rows["moon\0stale2"] = nil
end

-- ---------------------------------------------------------------------------
-- prefetchAround：前 1 后 3 目标选择
-- ---------------------------------------------------------------------------

local fetched = {}
local function makeFetchSource()
    return {
        fetchChapterContentAsync = function(_, _ref, chapter, cb)
            fetched[#fetched + 1] = tonumber(chapter.idx)
            UIManager:nextTick(function()
                cb({ title = chapter.title or "t", html = "<p>body</p>" })
            end)
        end,
    }
end

local function bindSession(stable_id, idx)
    Session.bind({
        source = makeFetchSource(),
        ref = { source_id = "wechat", stable_id = stable_id },
        toc = toc10,
        idx = idx,
    })
end

-- 中间章：{idx-1, idx+1, idx+2, idx+3}
do
    fetched = {}
    bindSession("pf1", 5)
    Materialize.prefetchAround(5)
    Stubs.flush()
    Assert.len(fetched, 4)
    Assert.eq(fetched[1], 4)
    Assert.eq(fetched[2], 6)
    Assert.eq(fetched[3], 7)
    Assert.eq(fetched[4], 8)
end

-- 第 1 章：前 1 越界跳过，只剩后 3
do
    fetched = {}
    bindSession("pf2", 1)
    Materialize.prefetchAround(1)
    Stubs.flush()
    Assert.len(fetched, 3)
    Assert.eq(fetched[1], 2)
    Assert.eq(fetched[2], 3)
    Assert.eq(fetched[3], 4)
end

-- 末章：后 3 全部越界，只剩前 1
do
    fetched = {}
    bindSession("pf3", 10)
    Materialize.prefetchAround(10)
    Stubs.flush()
    Assert.len(fetched, 1)
    Assert.eq(fetched[1], 9)
end

-- 已缓存章节跳过不重复拉取
do
    fetched = {}
    files["/tmp/moon-ch-pf4-6.html"] = "<!doctype html><html><body>x</body></html>"
    bindSession("pf4", 5)
    Materialize.prefetchAround(5)
    Stubs.flush()
    Assert.len(fetched, 3)
    Assert.contains(fetched, 4)
    Assert.contains(fetched, 7)
    Assert.contains(fetched, 8)
end

-- 不传 idx：用会话当前章
do
    fetched = {}
    bindSession("pf5", 5)
    Materialize.prefetchAround()
    Stubs.flush()
    Assert.len(fetched, 4)
    Assert.eq(fetched[1], 4)
    Assert.eq(fetched[2], 6)
end

-- 无会话：直接返回，不发任何拉取
do
    fetched = {}
    Session.clear()
    Materialize.prefetchAround(5)
    Stubs.flush()
    Assert.len(fetched, 0)
end

-- 会话无目录（count=0）：前 1 也不预取（该章可能不存在）
do
    fetched = {}
    Session.bind({
        source = makeFetchSource(),
        ref = { source_id = "wechat", stable_id = "pf6" },
        toc = {},
        idx = 5,
    })
    Materialize.prefetchAround(5)
    Stubs.flush()
    Assert.len(fetched, 0)
end

io.open = real_open
os.rename = old_rename
os.remove = old_remove
for _, k in ipairs({
    "json",
    "utils.db.toc",
    "utils.db.queue",
    "utils.db.progress",
    "utils.db.open",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
