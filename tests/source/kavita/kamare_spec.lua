--[[--
Kavita 漫画 → 外部 kamare 适配层：openBookAsync 的「源已自行接管」第三态。
kamare 模块用桩替换，只验证 moon 侧的注入契约与返回约定。

@module tests.source.kavita.kamare_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
        close = function() end,
        show = function(_, w) shown[#shown + 1] = w end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["10"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end

local comic_toc = {
    { idx = 1, chapterId = 77, volumeId = 5, libraryId = 10, seriesId = 42, pages = 30, format = "cbz", title = "第 1 话", toc_version = 3 },
}
package.preload["source.toc"] = function()
    return {
        read = function() return comic_toc end,
        index = function() return nil end,
        put = function() return true end,
        drop = function() end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return true end,
        isConnected = function() return true end,
        runWhenOnline = function(_, fn) fn() end,
    }
end

package.preload["ui/widget/progressbardialog"] = function()
    return { new = function() return { show = function() end, close = function() end, reportProgress = function() end } end }
end

package.preload["http.request"] = function()
    return {
        download = function() return { cancel = function() end } end,
        request = function(opts, cb)
            if (opts.url or ""):match("/api/Reader/get%-progress") then
                -- 续读：服务端已读 29/30 页 → 从第 30 页开始。
                cb({ code = 200, body = '{"pageNum":29,"volumeId":5,"chapterId":77,"seriesId":42,"libraryId":10}' })
            else
                cb({ code = 404, body = "" })
            end
            return { cancel = function() end }
        end,
    }
end

package.preload["book.store"] = function()
    return {
        touch = function() return true end,
        toc = function() return nil end,
        clearCache = function() return true end,
        markDeleted = function() return true end,
        reconcile = function() return { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false } end,
    }
end

package.preload["db.book"] = function()
    return { upsertLocal = function() return true end, touchPath = function() return true end, get = function() return nil end }
end

-- kamare 客户端单例：记录被注入的配置，并提供取图/尺寸桩。
local client = {
    base_url = nil,
    api_key = nil,
    auth_method = "bearer",
    bearer = "legacy-token",
    device_id = "dev-1",
    streamChapter = function(_, id) return { image_disposable = true, id = id } end,
    getFileDimensions = function()
        return { { pageNumber = 0, isWide = false }, { pageNumber = 1, isWide = true } }, 200
    end,
}
package.preload["kavitaclient"] = function() return client end

-- kamare viewer 类：捕获构造参数。
local captured_spec
package.preload["kamareimageviewer"] = function()
    return {
        new = function(_, spec)
            captured_spec = spec
            return { _aborted = false, virtual_document = {}, prefetchUpcomingTiles = function() end }
        end,
    }
end

local Kavita = require("source.kavita")
local source = Kavita.new()

local result, err, opts
source:openBookAsync(
    { source_id = "kavita", stable_id = "42", book = { title = "Comic Series", format = "cbz" } },
    {},
    function(p, e, o) result, err, opts = p, e, o end
)

-- 第三态：无 path、无 err，opts.handled=true → open.lua 跳过 ReaderUI。
Assert.is_nil(result)
Assert.is_nil(err)
Assert.not_nil(opts)
Assert.eq(opts.handled, true)

-- moon 配置注入 kamare 客户端单例（apiKey header 认证）
Assert.eq(client.base_url, "https://host:port/kavita")
Assert.eq(client.api_key, "test-key")
Assert.eq(client.auth_method, "apiKey")
Assert.is_nil(client.bearer)

-- viewer 构造契约
Assert.not_nil(captured_spec)
Assert.is_nil(captured_spec.ui) -- 不能传 ReaderUI，否则统计接口被猴补污染
Assert.eq(captured_spec.images_list_nb, 30)
Assert.eq(captured_spec.metadata.chapterId, 77)
Assert.eq(captured_spec.metadata.volumeId, 5)
Assert.eq(captured_spec.metadata.libraryId, 10)
Assert.eq(captured_spec.metadata.seriesId, 42)
Assert.eq(captured_spec.metadata.startPage, 30)
Assert.eq(captured_spec.title, "Comic Series")
-- 0-based 页号归一为 1-based（kamare 浏览器同款处理）
Assert.eq(captured_spec.preloaded_dimensions[1].pageNumber, 1)
Assert.eq(captured_spec.preloaded_dimensions[2].pageNumber, 2)
Assert.len(shown, 1)
