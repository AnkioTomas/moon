--[[--
source.moon 门面离线用例：listQuery 组装 / onEvent 事件分发 / progress 映射。

listQuery 是 local 函数，经 listLibraryAsync 捕获传给 client 的 query 观察；
onEvent 的 KOReader UI 依赖（NetworkMgr/StatsSync）按约定函数内延迟加载，这里用 preload 打桩。

@module tests.source.moon_spec
--]]

local Assert = require("support.assert")

-- 假客户端：记录入参、回放预设响应
local rec = {}
local client = {}

package.preload["utils.settings"] = function()
    return {
        getSource = function() return {} end,
    }
end

package.preload["source.moon.client"] = function()
    return {
        new = function() return client end,
    }
end

-- onEvent 延迟加载的 UI 依赖：记录调用
local sync = { push_calls = 0, last_source = nil, push_args = nil }

package.preload["stats.stats_sync"] = function()
    return {
        pushWithUi = function(self, a, b)
            sync.push_calls = sync.push_calls + 1
            sync.last_source = self
            sync.push_args = { a, b }
        end,
    }
end

-- 假 client 方法（moon.lua 一律冒号调用，首参是 client 自身）
function client:configured()
    return true
end

function client:listBooksAsync(query, cb)
    rec.query = query
    cb(rec.list_wire, rec.list_err)
    return { cancel = function() end }
end

function client:filtersAsync(cb)
    cb(rec.filters_wire, rec.filters_err)
    return { cancel = function() end }
end

function client:getProgressAsync(stable_id, cb)
    rec.progress_id = stable_id
    cb(rec.progress_wire, rec.progress_err)
    return { cancel = function() end }
end

function client:updateProgressAsync(payload, cb)
    rec.put_payload = payload
    if rec.put_err then
        cb(nil, rec.put_err)
    else
        cb({ ok = true })
    end
    return { cancel = function() end }
end

local Moon = require("source.moon")
local src = Moon.new()

local function resetRec()
    for k in pairs(rec) do rec[k] = nil end
end

-- listQuery：opts 缺省 → 默认 query
do
    resetRec()
    src:listLibraryAsync(nil, function() end)
    Assert.eq(rec.query.page, 1)
    Assert.eq(rec.query.pageSize, 50)
    Assert.eq(rec.query.search, "")
    Assert.eq(rec.query.series, "")
    Assert.eq(rec.query.category, "")
    Assert.is_nil(rec.query.favorite)
    Assert.is_nil(rec.query.finished)
    Assert.is_nil(rec.query.author)
end

-- listQuery：opts 全字段 → 键名映射（page_size → pageSize）
do
    resetRec()
    rec.list_wire = {
        data = { { filename = "a.epub", title = "A", percent = 42 } },
        count = 1,
    }
    local result
    src:listLibraryAsync({
        page = 3,
        page_size = 10,
        search = "科幻",
        series = "s",
        category = "c",
    }, function(r) result = r end)
    Assert.eq(rec.query.page, 3)
    Assert.eq(rec.query.pageSize, 10)
    Assert.eq(rec.query.search, "科幻")
    Assert.eq(rec.query.series, "s")
    Assert.eq(rec.query.category, "c")
    -- wire 经 Mapper.list 映射
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].ref.stable_id, "a.epub")
    Assert.eq(result.data[1].percent, 42)
end

-- filtersAsync：服务端字段收口成 category / series。
do
    resetRec()
    rec.filters_wire = {
        data = {
            categories = { "小说", "技术" },
            groupNames = { "第一辑" },
            authors = { "不应透传" },
        },
    }
    local result
    src:filtersAsync(function(r) result = r end)
    Assert.len(result.data.category, 2)
    Assert.eq(result.data.category[1], "小说")
    Assert.len(result.data.series, 1)
    Assert.eq(result.data.series[1], "第一辑")
    Assert.is_nil(result.data.authors)
end

-- listLibraryAsync 错误：{ message = ... } 取 message，字符串原样透传
do
    resetRec()
    rec.list_err = { message = "服务器错误" }
    local result, err
    src:listLibraryAsync({}, function(r, e) result, err = r, e end)
    Assert.is_nil(result)
    Assert.eq(err, "服务器错误")

    rec.list_err = "网络故障"
    src:listLibraryAsync({}, function(r, e) result, err = r, e end)
    Assert.eq(err, "网络故障")
end

-- onEvent：document_close/suspend 推统计；其余事件无动作
do
    sync.push_calls = 0

    src:onEvent("document_close")
    Assert.eq(sync.push_calls, 1)
    Assert.eq(sync.last_source, src)
    Assert.is_false(sync.push_args[1])
    Assert.is_false(sync.push_args[2])

    src:onEvent("suspend")
    Assert.eq(sync.push_calls, 2)

    src:onEvent("reader_ready")
    src:onEvent("page_changed")
    Assert.eq(sync.push_calls, 2)
end

-- getProgressAsync：wire 表 → ProgressPosition（percent/100、chapter_idx、locator）
do
    resetRec()
    rec.progress_wire = { data = { percent = 42, chapter_idx = 3, locator = "ptr" } }
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(rec.progress_id, "a.epub")
    Assert.eq(pos.fraction, 0.42)
    Assert.eq(pos.chapter_idx, 3)
    Assert.eq(pos.locator, "ptr")
end

-- getProgressAsync：data 为纯数字（百分数）也映射为 fraction
do
    resetRec()
    rec.progress_wire = { data = 55 }
    local pos
    src:getProgressAsync({ stable_id = "a.epub" }, function(p) pos = p end)
    Assert.eq(pos.fraction, 0.55)
end

-- getProgressAsync：拉取失败透传错误；wire 无法映射时报「进度为空」
do
    resetRec()
    rec.progress_err = { message = "无进度" }
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "无进度")

    rec.progress_wire = "garbage"
    rec.progress_err = nil
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "进度为空")
end

-- putProgressAsync：fraction 钳制、spine/percent 组装
do
    resetRec()
    local ok, err
    src:putProgressAsync({ stable_id = "a.epub" }, { fraction = 0.5, chapter_idx = 2 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(rec.put_payload.filename, "a.epub")
    Assert.eq(rec.put_payload.frac, 0.5)
    Assert.eq(rec.put_payload.spine, 2)
    Assert.eq(rec.put_payload.page, 0)
    Assert.eq(rec.put_payload.percent, "50.00%")

    -- fraction 超 1 按百分数钳制（42 → 0.42）；chapter_idx 缺省 spine = 0
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 42 }, function() end)
    Assert.eq(rec.put_payload.frac, 0.42)
    Assert.eq(rec.put_payload.spine, 0)
    Assert.eq(rec.put_payload.percent, "42.00%")

    -- pos 缺省：fraction 0
    src:putProgressAsync({ stable_id = "b.epub" }, nil, function() end)
    Assert.eq(rec.put_payload.frac, 0)
    Assert.eq(rec.put_payload.percent, "0.00%")

    -- 失败透传
    rec.put_err = "网络故障"
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 0.1 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_nil(ok)
    Assert.eq(err, "网络故障")
end

-- 还原 preload/loaded，避免影响本文件之后的用例
for _, name in ipairs({
    "utils.settings",
    "source.moon.client",
    "ui/network/manager",
    "stats.stats_sync",
    "source.moon",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
