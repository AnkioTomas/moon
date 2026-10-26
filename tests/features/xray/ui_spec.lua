--[[-- X-Ray 入口：刷新 / 分析全书都走后台任务，划词查询可取消。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
package.preload["ui.themes.widgets.list"] = function() return {} end
local viewer
package.preload["ui.themes.widgets.text_viewer"] = function()
    return { new = function(_self, o)
        viewer = o
        o.show = function() o.shown = true end
        return o
    end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end }
end
package.preload["features.xray.kinds"] = function() return { label = function() return "人物" end } end
package.preload["features.xray.db"] = function() return {} end
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_, opts)
        opts.show = function() toasts[#toasts + 1] = opts.text end
        opts.close = function() end
        return opts
    end }
end
local dialogs = {}
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return { new = function(_, opts)
        opts.show = function() dialogs[#dialogs + 1] = opts end
        opts.close = function() opts.closed = true end
        opts.showWhile = function(self, fn, ...)
            self:show()
            local ok, result = pcall(fn, ...)
            if not ok then self:close(); error(result, 0) end
            return result
        end
        return opts
    end }
end
local configured = true
package.preload["ai"] = function()
    return { isConfigured = function() return configured end }
end
local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local identity = { source_id = "moon", stable_id = "book-1" }
package.preload["reader.session"] = function()
    return { current = function() return { identity = identity } end }
end

local captured
package.preload["features.xray.marks"] = function() return { invalidate = function() end } end
local local_entities = {}
local looked_up
local scan_progress
package.preload["features.xray.fetch"] = function()
    return {
        comprehensive = function(ui, current, cb)
            captured = { ui = ui, identity = current, cb = cb }
            return { cancel = function() captured.cancelled = true end }
        end,
        scanProgress = function() return scan_progress end,
        findLocal = function(current, word)
            Assert.eq(current, identity)
            return local_entities[word]
        end,
        lookupWord = function(ui, current, word, cb)
            looked_up = word
            return { cancel = function() looked_up = "cancelled" end }
        end,
        scanBook = function(current, text)
            return function() return { cancel = function() end } end
        end,
    }
end
local confirm
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_, opts)
        opts.show = function() confirm = opts end
        return opts
    end }
end
local extract_cb
package.preload["features.reflow.extract"] = function()
    return { run = function(_ui, cb) extract_cb = cb; return { cancel = function() end } end }
end
local running_task
package.preload["workers.tasks"] = function()
    return { get = function() return running_task end }
end
---@type BookTask|nil, BookTask|nil
local started, followed
package.preload["workers.ui.task_dialog"] = function()
    return {
        start = function(spec) started = spec end,
        follow = function(task) followed = task end,
    }
end

local ui = {}
require("features.xray.ui").refresh(ui)
-- 按当前位置更新：ai 类后台任务，与全书分析共用 key
Assert.eq(started.kind, "ai")
Assert.eq(started.key, "xray\0moon\0book-1")
Assert.is_true(started.restartable)
local done_result
local handle = started.run(function() end, function(r) done_result = r end)
Assert.eq(captured.ui, ui)
handle.cancel()
Assert.is_true(captured.cancelled)
captured.cb({ characters = { 1 }, locations = {}, terms = {} })
Assert.is_true(done_result.ok)
started.on_done(done_result)
Assert.eq(toasts[#toasts], "X-Ray 已更新：人物 %1，地点 %2，专有名词 %3")

-- 离线：立即提示，不入队。
started, connected = nil, false
require("features.xray.ui").refresh(ui)
Assert.is_nil(started)
Assert.eq(toasts[#toasts], "网络不可用，请先连接 Wi-Fi")
connected = true

-- 实体详情：居中弹窗卡片，不全屏。
require("features.xray.ui").showEntity({ kind = "character", name = "李善德", role = "主角" })
Assert.is_true(viewer.shown)
Assert.eq(viewer.title, "李善德")
Assert.is_false(viewer.fullscreen)

-- 划词查：本地已收录的直接出详情，离线、未配置 AI 也行，不走 AI
local_entities["翠翠"] = { kind = "character", name = "翠翠", role = "主角" }
connected, configured = false, false
require("features.xray.ui").lookup(ui, " 翠翠 ")
Assert.eq(viewer.title, "翠翠")
Assert.is_nil(looked_up)

-- 没收录：离线时提示网络，联网才交给 AI
configured = true
require("features.xray.ui").lookup(ui, "爷爷")
Assert.is_nil(looked_up)
Assert.eq(toasts[#toasts], "网络不可用，请先连接 Wi-Fi")
connected = true
require("features.xray.ui").lookup(ui, "爷爷")
Assert.eq(looked_up, "爷爷")
dialogs[#dialogs].on_cancel()
Assert.eq(looked_up, "cancelled", "查询中可取消")

-- 分析全书：确认 → 入后台任务（ai 类、可重跑），取字在任务里
started = nil
require("features.xray.ui").scanBook(ui, identity)
Assert.is_nil(started, "确认前不入队")
confirm.ok_callback()
---@cast started +BookTask
Assert.eq(started.kind, "ai")
Assert.eq(started.key, "xray\0moon\0book-1")
Assert.is_true(started.restartable)
Assert.is_true(started.retryable({ ok = false }))
Assert.is_nil(extract_cb, "入队前不取字")
local scan_done
started.run(function() end, function(r) scan_done = r end)
extract_cb(nil, "文档没有可提取的文字")
Assert.is_false(scan_done.ok)

-- 上次没分析完：确认框报断点
scan_progress = { done = 3, total = 10 }
require("features.xray.ui").scanBook(ui, identity)
Assert.eq(confirm.text, "上次全书分析进行到第 %1 / %2 段，继续从断点分析？")
scan_progress = nil

-- 同一本书已在分析：只跟随进度，不再取字
running_task, confirm = { key = "xray\0moon\0book-1" }, nil
require("features.xray.ui").scanBook(ui, identity)
Assert.eq(followed, running_task)
Assert.is_nil(confirm)

-- 自动预取：没网 / 没配 AI / 已有任务都不入队，返回 false 让下次翻页再试
running_task = nil
connected = false
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
connected, configured = true, false
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
configured, running_task = true, { key = "x" }
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
running_task = nil

return true
