--[[--
storage.setting：非 Kindle 隐藏诊断文件入口且不扫盘；Kindle 展示诊断行、
多选删除用 TextViewer 卡片防溢出、删后清旧缓存并替换在飞任务。
@module tests.features.storage.setting_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")

Stubs.install()
Themed.install()

local built_rows = {}
package.loaded["ui.themes.widgets.row"] = {
    widget = function(opts)
        built_rows[#built_rows + 1] = opts
        return opts
    end,
}

package.loaded["features.storage"] = {
    disk = function() return { total = 1000, used = 400, available = 600 } end,
}

local measure_calls, measure_cancelled = 0, 0
local last_measure_cb
package.loaded["features.storage.usage"] = {
    CATEGORIES = {},
    measureAsync = function(cb)
        measure_calls = measure_calls + 1
        last_measure_cb = cb
        return { cancel = function() measure_cancelled = measure_cancelled + 1 end }
    end,
}

local dump_roots = {}
local scan_calls, scan_cancelled = 0, 0
local last_scan_cb
local remove_result
local removed_arg
package.loaded["features.storage.dumps"] = {
    defaultRoots = function() return dump_roots end,
    scanAsync = function(cb)
        scan_calls = scan_calls + 1
        last_scan_cb = cb
        return { cancel = function() scan_cancelled = scan_cancelled + 1 end }
    end,
    removeMany = function(list)
        removed_arg = list
        return remove_result
    end,
}

require("features.storage.setting")

local Ext = require("utils.extension")
local section_entry
for _idx, item in ipairs(Ext.list("setting.device_section")) do
    if item.id == "storage" then section_entry = item end
end
Assert.not_nil(section_entry)

local function buildRows(desktop)
    built_rows = {}
    local secs = section_entry.sections(desktop)
    for _i, sec in ipairs(secs) do
        for _j, row_fn in ipairs(sec.rows) do
            if type(row_fn) == "function" then
                pcall(row_fn, 500)
            end
        end
    end
    return built_rows
end

local function findRow(rows, title)
    for _i, row in ipairs(rows) do
        if row.title == title then return row end
    end
end

-- 1. 非 Kindle（defaultRoots 为空）：不显示诊断行，也不起扫描任务。
local updates = 0
local desktop = {
    closed = false,
    settings_overlay = { updateView = function() updates = updates + 1 end },
}
dump_roots = {}
local rows = buildRows(desktop)
Assert.eq(scan_calls, 0, "非 Kindle 不得触发诊断文件扫描")
Assert.is_nil(findRow(rows, "崩溃与诊断文件"), "非 Kindle 不显示诊断文件行")

-- 2. Kindle（有扫描根）：先显示「计算中…」，扫描完显示数量和体积。
dump_roots = { "/mnt/us" }
rows = buildRows(desktop)
Assert.eq(scan_calls, 1)
local dump_row = findRow(rows, "崩溃与诊断文件")
Assert.not_nil(dump_row)
Assert.eq(dump_row.status, "计算中…")
Assert.is_nil(dump_row.callback)

local f1 = { path = "/mnt/us/Indexer_Dump_1.txt", root = "/mnt/us", name = "Indexer_Dump_1.txt", size = 1024, mtime = 1700000000 }
local f2 = { path = "/mnt/us/cvm_1_a.core", root = "/mnt/us", name = "cvm_1_a.core", size = 2048, mtime = 0 }
last_scan_cb({ items = { f1, f2 }, total = 3072, count = 2 })
Assert.eq(updates, 1)

rows = buildRows(desktop)
Assert.eq(scan_calls, 1, "新鲜缓存内不重复扫描")
dump_row = findRow(rows, "崩溃与诊断文件")
Assert.not_nil(dump_row.callback)
Assert.matches(dump_row.status, "2 个")

-- 3. 点开诊断文件列表：副标题含位置与时间，不重复文件名；右侧只有体积。
dump_row.callback()
local list = Themed.last("list")
Assert.not_nil(list)
Assert.is_true(list.multi)
Assert.eq(list.left_icon, "delete")
Assert.len(list.items, 2)
Assert.eq(list.items[1].text, f1.name)
Assert.is_nil(list.items[1].subtitle:find(f1.name, 1, true), "副标题不重复文件名")
Assert.matches(list.items[1].subtitle, "设备存储")
Assert.matches(list.items[2].subtitle, "未知时间")
Assert.is_nil(list.items[1].mandatory:find("·", 1, true), "右侧只显示体积")

-- 4. 未选直接点删除：弹提示，不开确认框。
list.left_callback()
Assert.eq(Themed.last("toast").text, "请先选择要删除的文件")
Assert.is_nil(Themed.last("text_viewer"))

-- 5. 选中全部点删除：用 TextViewer 卡片确认（避免 Confirm 溢出），且能替换在飞扫描。
list.items[1].checked = true
list.items[2].checked = true
list.left_callback()
local confirm = Themed.last("text_viewer")
Assert.not_nil(confirm)
Assert.eq(confirm.fullscreen, false)
Assert.eq(confirm.title, "删除诊断文件")
Assert.matches(confirm.text, f1.name)
Assert.matches(confirm.text, f2.name)
Assert.len(confirm.buttons, 2)

-- 模拟此时已有在飞扫描和统计，force=true 必须取消旧任务并启动新任务。
desktop.storage_dumps_job = { cancel = function() scan_cancelled = scan_cancelled + 1 end }
desktop.storage_job = { cancel = function() measure_cancelled = measure_cancelled + 1 end }
remove_result = { removed = { f1 }, errors = { { item = f2, err = "replaced" } } }

local before_scan, before_measure = scan_calls, measure_calls
confirm.buttons[2].callback()

Assert.is_true(confirm.closed)
Assert.is_true(list.closed)
Assert.len(removed_arg, 2)
Assert.is_nil(desktop.storage_dumps, "删完后立即失效旧缓存")
Assert.eq(scan_cancelled, 1, "force 重扫取消在飞扫描")
Assert.eq(measure_cancelled, 1, "force 重算取消在飞统计")
Assert.eq(scan_calls, before_scan + 1)
Assert.eq(measure_calls, before_measure + 1)

-- 6. 部分失败：用 TextViewer 卡片展示结果，只有单个「知道了」按钮。
local report = Themed.last("text_viewer")
Assert.eq(report.title, "删除结果")
Assert.eq(report.fullscreen, false)
Assert.matches(report.text, "已删除 1 个，有 1 个未能删除")
Assert.matches(report.text, "文件已被替换，已跳过")
Assert.len(report.buttons, 1)
Assert.eq(report.buttons[1].text, "知道了")
report.buttons[1].callback()
Assert.is_true(report.closed)

-- 7. 全部删除成功：弹 toast，不弹结果框。
last_scan_cb({ items = { f2 }, total = 2048, count = 1 })
rows = buildRows(desktop)
findRow(rows, "崩溃与诊断文件").callback()
local list2 = Themed.last("list")
list2.items[1].checked = true
list2.left_callback()
local confirm2 = Themed.last("text_viewer")
remove_result = { removed = { f2 }, errors = {} }
confirm2.buttons[2].callback()
Assert.eq(Themed.last("toast").text, "已删除 1 个")
Assert.eq(Themed.last("text_viewer"), confirm2, "全部成功不再弹结果卡片")

-- 8. 扫描结果为 0：显示「没有这类文件」且不可点击。
last_scan_cb({ items = {}, total = 0, count = 0 })
rows = buildRows(desktop)
dump_row = findRow(rows, "崩溃与诊断文件")
Assert.eq(dump_row.status, "没有这类文件")
Assert.is_nil(dump_row.callback)

return true
