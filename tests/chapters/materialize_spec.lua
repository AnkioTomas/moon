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

io.open = real_open
os.rename = old_rename
os.remove = old_remove
