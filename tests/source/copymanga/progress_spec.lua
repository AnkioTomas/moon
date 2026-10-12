--[[--
拷贝漫画进度：query 拉浏览记录，chapter2 推当前章。

@module tests.source.copymanga.progress_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local fake_client = {}
local logged_in = true
local toc_store = {}

local function stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = nil
end

stub("json", function()
    return {
        decode = require("support.json_stub").decode,
        encode = require("support.json_stub").encode,
    }
end)
stub("book.books_db", function()
    return {
        getToc = function(source_id, stable_id)
            return toc_store[source_id .. "\31" .. stable_id]
        end,
        setToc = function(source_id, stable_id, payload)
            toc_store[source_id .. "\31" .. stable_id] = payload
            return true
        end,
        get = function() return nil end,
    }
end)
stub("utils.settings", function()
    return {
        getSource = function() return { token = "tok" } end,
        saveSource = function() end,
    }
end)
stub("source.copymanga.auth", function()
    return { hasSession = function() return logged_in end }
end)
stub("source.copymanga.client", function()
    return {
        new = function() return fake_client end,
        headers = function() return {} end,
        normalizeBaseUrl = function(url) return url end,
    }
end)

package.loaded["source.toc"] = nil
package.loaded["source.copymanga"] = nil
local Copymanga = require("source.copymanga")
local Toc = require("source.toc")
local src = Copymanga.new()

local IDENTITY = {
    source_id = "copymanga",
    stable_id = "test-comic",
    chapter_idx = 2,
}

Toc.put("copymanga", "test-comic", {
    { idx = 1, uid = "chap-1", title = "第一话" },
    { idx = 2, uid = "chap-2", title = "第二话" },
    { idx = 3, uid = "chap-3", title = "第三话" },
})

do
    logged_in = false
    local pos, err, meta
    src:getProgressAsync(IDENTITY, function(p, e, m) pos, err, meta = p, e, m end)
    Stubs.flush()
    Assert.is_nil(pos)
    Assert.is_nil(err)
    Assert.is_true(meta.empty)
    logged_in = true
end

do
    fake_client.getProgressAsync = function(_, _, cb)
        cb({ results = { browse = nil } })
        return { cancel = function() end }
    end
    local pos, err, meta
    src:getProgressAsync(IDENTITY, function(p, e, m) pos, err, meta = p, e, m end)
    Assert.is_nil(pos)
    Assert.is_nil(err)
    Assert.is_true(meta.empty)
end

do
    fake_client.getProgressAsync = function(_, _, cb)
        cb({
            results = {
                browse = { chapter_uuid = "chap-2", chapter_name = "第二话" },
            },
        })
        return { cancel = function() end }
    end
    local pos, err
    src:getProgressAsync(IDENTITY, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(pos.chapter_idx, 2)
    Assert.eq(pos.chapter_title, "第二话")
    Assert.eq(pos.fraction, 1 / 3)
    Assert.eq(pos.extra.chapter_uid, "chap-2")
end

do
    fake_client.getProgressAsync = function(_, _, cb)
        cb(nil, "网络错误")
        return { cancel = function() end }
    end
    local pos, err
    src:getProgressAsync(IDENTITY, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "网络错误")
end

-- 云端读到缓存目录里没有的新话：缓存没过期也强制重拉目录再定位。
do
    local detail_calls = 0
    fake_client.getProgressAsync = function(_, _, cb)
        cb({ results = { browse = { chapter_uuid = "chap-4", chapter_name = "第四话" } } })
        return { cancel = function() end }
    end
    fake_client.detailAsync = function(_, _, cb)
        detail_calls = detail_calls + 1
        cb({ results = { comic = { path_word = "test-comic" } } })
        return { cancel = function() end }
    end
    fake_client.chaptersAsync = function(_, _, _, cb)
        cb({
            { uuid = "chap-1", name = "第一话" }, { uuid = "chap-2", name = "第二话" },
            { uuid = "chap-3", name = "第三话" }, { uuid = "chap-4", name = "第四话" },
        })
        return { cancel = function() end }
    end
    local pos, err
    src:getProgressAsync(IDENTITY, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(detail_calls, 1)
    Assert.eq(pos.chapter_idx, 4)
    Assert.eq(pos.extra.chapter_uid, "chap-4")
end

-- 没有章号不能默认推第一章，否则会把云端浏览记录改回开头。
do
    local ok, err
    src:putProgressAsync({ source_id = "copymanga", stable_id = "test-comic" }, {},
        function(value, e) ok, err = value, e end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "缺少章节信息")
end

do
    logged_in = false
    local ok, err
    src:putProgressAsync(IDENTITY, { chapter_idx = 2 }, function(value, e) ok, err = value, e end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "请先登录拷贝漫画账号")
    logged_in = true
end

do
    local pushed
    fake_client.chapterAsync = function(_, stable_id, uid, cb)
        pushed = { stable_id = stable_id, uid = uid }
        cb({ code = 200 })
        return { cancel = function() end }
    end
    local ok, err
    src:putProgressAsync(IDENTITY, { chapter_idx = 3 }, function(value, e) ok, err = value, e end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(pushed.stable_id, "test-comic")
    Assert.eq(pushed.uid, "chap-3")
end

do
    local ok, err
    src:putProgressAsync(IDENTITY, {
        chapter_idx = 1,
        extra = { chapter_uid = "chap-1", chapter_idx = 1 },
    }, function(value, e) ok, err = value, e end)
    Assert.is_true(ok)
    Assert.is_nil(err)
end

Stubs.flush()
