--[[--
source.wechat 适配器离线用例（Auth / chapter stub）

@module tests.wechat_source_spec
--]]

local Assert = require("support.assert")

package.preload["source.wechat.setting"] = function()
    return {
        defaults = function()
            return {}
        end,
        load = function()
            return {}
        end,
        save = function() end,
    }
end

package.preload["source.wechat.auth"] = function()
    return {
        hasSession = function()
            return true
        end,
    }
end

package.preload["source.wechat.chapter"] = function()
    return {
        ensure = function(_id, _idx, _path, _ch)
            return true
        end,
    }
end

package.preload["source.wechat.api"] = function()
    local Api = {}
    Api.__index = Api
    function Api:new(o)
        return setmetatable(o or {}, self)
    end
    function Api:ping()
        return { ok = true }
    end
    function Api:listShelf()
        return { data = { { id = "1", title = "A" } }, count = 1 }
    end
    function Api:search(keyword, pageSize)
        return {
            data = { { id = "s1", title = keyword, pageSize = pageSize } },
            count = 1,
        }
    end
    function Api:listRecent(limit)
        return nil, "no recent"
    end
    function Api:getProgress(id)
        return { data = { progress = 1, id = id } }
    end
    function Api:updateProgress(id, frac, spine)
        return { ok = true, id = id, frac = frac, spine = spine }
    end
    function Api:coverRequest(id)
        return { url = "https://x/" .. id, headers = {} }
    end
    function Api:bookInfo(id)
        return { id = id, title = "detail" }
    end
    function Api:chapterInfo(id)
        return { chapters = { { idx = 1, title = "一", uid = "u1" } }, bookId = id }
    end
    return Api
end

package.loaded["source.wechat.setting"] = nil
package.loaded["source.wechat.auth"] = nil
package.loaded["source.wechat.chapter"] = nil
package.loaded["source.wechat.api"] = nil
package.loaded["source.wechat"] = nil

local WeChat = require("source.wechat")

-- meta
do
    local m = WeChat.meta()
    Assert.eq(m.id, "wechat")
    Assert.not_nil(m.name)
end

local src = WeChat.new()

-- capabilities：页面实际查询的能力位
do
    local c = src:capabilities()
    Assert.is_true(c.store)
    Assert.is_true(c.chapters)
    Assert.is_false(c.stats)
    Assert.is_nil(c.search)
    Assert.is_nil(c.progress_sync)
    Assert.is_nil(c.stats_import)
    Assert.is_nil(c.filters)
end

Assert.is_true(src:configured())

-- listLibrary：无 search → shelf；有 search → search
do
    local res = src:listLibrary()
    Assert.eq(res.data[1].id, "1")
    res = src:listLibrary({ search = "三体", page_size = 5 })
    Assert.eq(res.data[1].title, "三体")
end

-- listStore
do
    local res = src:listStore({ search = "x", page_size = 9 })
    Assert.eq(res.data[1].title, "x")
end

-- recentBooks：listRecent 失败则兜底 shelf 并截断
do
    -- 扩大 shelf
    package.loaded["source.wechat.api"] = nil
    package.preload["source.wechat.api"] = function()
        local Api = {}
        Api.__index = Api
        function Api:new(o)
            return setmetatable(o or {}, self)
        end
        function Api:listRecent()
            return nil, "fail"
        end
        function Api:listShelf()
            local data = {}
            for i = 1, 20 do
                data[i] = { id = tostring(i) }
            end
            return { data = data, count = 20 }
        end
        return Api
    end
    package.loaded["source.wechat"] = nil
    local W = require("source.wechat")
    local s = W.new({})
    local res, err = s:recentBooks(5)
    Assert.is_nil(err)
    Assert.eq(res.count, 5)
    Assert.len(res.data, 5)
end

-- 整本下载拒绝；按章方法转发
do
    local ok, err = src:downloadBook("id", "/tmp/x")
    Assert.is_nil(ok)
    Assert.not_nil(err)

    Assert.is_nil(src:probeFileSize("id"))

    local toc = src:getToc("bid")
    Assert.eq(toc.chapters[1].uid, "u1")

    local detail = src:getBookDetail("bid")
    Assert.eq(detail.title, "detail")

    Assert.is_true(src:ensureChapter("bid", 1, "/tmp/ch.epub", toc.chapters[1]))
end

-- 不支持的能力返回错误串
do
    local _, err = src:filters()
    Assert.not_nil(err)
    _, err = src:readingInsight()
    Assert.not_nil(err)
end
