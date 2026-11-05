--[[-- X-Ray 入口：刷新 / 分析全书都走后台任务，划词查询可取消。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(value) return value end }
end
local list_options
package.preload["ui.themes.widgets.list"] = function()
    return { new = function(_self, opts)
        list_options = opts
        opts.tabs = { active = "character" }
        opts.setItems = function() end
        opts.show = function() end
        return opts
    end }
end
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
local cleared_removed, reset_result = {}, true
package.preload["features.xray.db"] = function()
    return {
        clearRemoved = function(source_id, stable_id)
            cleared_removed[#cleared_removed + 1] = source_id .. "\0" .. stable_id
            return true
        end,
        reset = function(source_id, stable_id)
            cleared_removed[#cleared_removed + 1] = "reset\0" .. source_id .. "\0" .. stable_id
            return reset_result
        end,
        list = function() return {} end,
    }
end
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
local invalidations = 0
package.preload["features.xray.marks"] = function()
    return { invalidate = function() invalidations = invalidations + 1 end }
end
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
        scanBook = function(current, path)
            return function(report, done)
                -- extract 成功后必须传临时文件路径，不能再把路径字符串当正文。
                Assert.eq(type(path), "string")
                Assert.is_true(path:find("%.txt") ~= nil or path:find("/") ~= nil)
                done({ ok = true })
                return { cancel = function() end }
            end
        end,
    }
end
---@type string|nil
local confirm_text
---@type fun()|nil
local confirm_callback
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_, opts)
        opts.show = function()
            confirm_text = opts.text
            confirm_callback = opts.ok_callback
        end
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
---@type { items: { text: string, callback: fun() }[] }|nil
local sheet
package.preload["ui.themes.widgets.sheet"] = function()
    return { new = function(_self, opts)
        sheet = opts
        opts.show = function() end
        return opts
    end }
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
-- 显式重生先清墓碑，否则删过的实体加不回来
Assert.eq(cleared_removed[1], "moon\0book-1")
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

-- 分析全书：确认 → 清墓碑 → 入后台任务（ai 类、可重跑），取字在任务里
started = nil
cleared_removed = {}
require("features.xray.ui").scanBook(ui, identity)
Assert.is_nil(started, "确认前不入队")
Assert.len(cleared_removed, 0, "点继续前不清墓碑")
confirm_callback()
Assert.eq(cleared_removed[1], "moon\0book-1", "确认后清墓碑")
---@cast started +BookTask
Assert.eq(started.kind, "ai")
Assert.eq(started.key, "xray\0moon\0book-1")
Assert.is_true(started.restartable)
Assert.is_true(started.retryable({ ok = false }))
Assert.is_nil(extract_cb, "入队前不取字")
---@type { ok: boolean, err?: string }|nil
local scan_done
started.run(function() end, function(r) scan_done = r end)
extract_cb(nil, "文档没有可提取的文字")
Assert.is_false(scan_done.ok)

scan_done = nil
started.run(function() end, function(r) scan_done = r end)
extract_cb("/tmp/reflow_extract_xray.txt")
---@cast scan_done -nil
Assert.is_true(scan_done.ok, "extract 交出路径后应进入 scanBook")

-- 上次没分析完：确认框报断点
scan_progress = { done = 3, total = 10 }
require("features.xray.ui").scanBook(ui, identity)
Assert.eq(confirm_text, "上次全书分析进行到第 %1 / %2 段，继续从断点分析？")
scan_progress = nil

-- 同一本书已在分析：只跟随进度，不再取字
running_task, confirm_callback = { key = "xray\0moon\0book-1" }, nil
require("features.xray.ui").scanBook(ui, identity)
Assert.eq(followed, running_task)
Assert.is_nil(confirm_callback)

-- 自动预取：没网 / 没配 AI / 已有任务都不入队，返回 false 让下次翻页再试
running_task = nil
connected = false
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
connected, configured = true, false
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
configured, running_task = true, { key = "x" }
Assert.is_false(require("features.xray.ui").prefetch(ui, false))
running_task = nil

-- 主菜单中可打开重置项；确认时检查运行任务，成功后清数据并刷新标记。
local XrayUI = require("features.xray.ui")
XrayUI.openMain(ui)
list_options.left_callback()
local reset_item
for _idx, item in ipairs(sheet.items) do
    if item.text == "重置此书 X-Ray" then reset_item = item end
end
Assert.not_nil(reset_item)
reset_item.callback()
Assert.eq(confirm_text, "重置此书 X-Ray？将清空已收录的人物 / 地点 / 专有名词、删除记录与分析进度，之后需重新生成。")
local invalidations_before_reset = invalidations
running_task = { key = "xray\0moon\0book-1" }
confirm_callback()
Assert.eq(toasts[#toasts], "本书 X-Ray 正在生成，请先取消或等待完成")
Assert.eq(invalidations, invalidations_before_reset)
running_task = nil
confirm_callback()
Assert.eq(cleared_removed[#cleared_removed], "reset\0moon\0book-1")
Assert.eq(toasts[#toasts], "已重置此书 X-Ray")
Assert.eq(invalidations, invalidations_before_reset + 1)

-- 数据库失败时明确提示，不冒充成功。
reset_result = false
reset_item.callback()
confirm_callback()
Assert.eq(toasts[#toasts], "重置失败")
Assert.eq(invalidations, invalidations_before_reset + 1)

return true
