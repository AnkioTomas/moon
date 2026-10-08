--[[--
多册选册列表：已下载册仍能构建（回归：循环变量 `_` 曾遮蔽 gettext 导致
`_("已下载")` 崩溃）。

@module tests.source.kavita.open_picker_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end

local JsonStub = require("support.json_stub")
package.preload["json"] = function()
    return { encode = JsonStub.encode, decode = JsonStub.decode }
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
        close = function() end,
    }
end

local cfg = { base_url = "https://host:port/kavita", api_key = "test-key", libraries = { ["8"] = true } }
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end }
end

local toc = {
    { idx = 1, chapterId = 11, volumeId = 5, libraryId = 8, seriesId = 42, pages = 100, pagesRead = 100, format = "epub", title = "卷一", toc_version = 3 },
    { idx = 2, chapterId = 12, volumeId = 6, libraryId = 8, seriesId = 42, pages = 200, pagesRead = 50, format = "epub", title = "卷二" },
}
package.preload["source.toc"] = function()
    return {
        read = function() return toc end,
        index = function() return nil end,
        put = function() return true end,
        drop = function() end,
    }
end

-- 指向真实存在的文件，让「已下载」判定为真 → 触发 `_("已下载")` 取值。
local existing = require("support.config").root() .. "/book.koplugin/source/kavita.lua"
package.preload["db.book"] = function()
    return {
        upsertLocal = function() return true end,
        touchPath = function() return true end,
        get = function() return { stable_id = "42:11", path = existing } end,
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

local picker
package.preload["ui.views.popup"] = function()
    return {
        single = function(opts)
            picker = opts
            return { close = function() end }
        end,
    }
end

package.preload["http.request"] = function()
    return { download = function() return { cancel = function() end } end }
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

local Kavita = require("source.kavita")
Kavita.new():openBookAsync(
    { source_id = "kavita", stable_id = "42", book = { title = "Harry Potter", format = "epub" } },
    {},
    function() end
)

Assert.not_nil(picker)
Assert.len(picker.items, 2)
-- 构建列表本身不崩，且已下载标记正常（回归点）。
Assert.eq(picker.items[1].mandatory, "已下载")
Assert.eq(picker.items[2].mandatory, "已下载")
-- 预选「在读」那册（卷二 pagesRead=50/200）。
Assert.eq(picker.current, 2)
