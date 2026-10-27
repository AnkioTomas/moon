--[[--
Kavita 卷列表：真实 list 的行尾控件命中（04 A9）、状态字优先级、缓存整部、删除保护、
暂停 / 恢复与进度框收尾。

真实 list 与 Kit 一起用：A9 的「点图标不关窗」只能靠真行 / 真按钮的事件顺序证明。
Themed 只负责记录弹窗参数；装完把它的 list 桩摘掉，require 真组件。

@module tests.extensions.kavita.volume_list_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Themed = require("support.theme_stubs")
Themed.install()
-- 真实的 list：Themed 的桩会把 item.widget 丢掉，A9 就无从验证。
package.preload["ui.themes.widgets.list"] = nil
package.loaded["ui.themes.widgets.list"] = nil

-- 缓存层另有 cache_spec；这里只关心 UI 传了什么、显示了什么。
package.loaded["utils.log"] = {
    info = function() end, warn = function() end, err = function() end, dbg = function() end,
}
local offline = false
package.loaded["ui/network/manager"] = { isConnected = function() return not offline end }

local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
local RealCache = dofile(PLUGIN .. "/moonsource_kavita/cache.lua")

local st, calls = {}, {}
local function reset(overrides)
    calls = { enqueue = {}, delete = {}, retry = {}, pause = 0, resume = 0 }
    st.probe = { ok = true, state = "enhanced", capabilities = {
        status = true, queue = true, queue_control = true,
        enqueue = true, delete = true, estimate = true,
    } }
    st.queue = { state = "idle", entries = {}, percent = 0, bytes_done = 0, bytes_total = 0 }
    st.queue_code = nil
    st.statuses, st.resumes = {}, {}
    st.open_chapter = nil
    st.estimate = { chapters = 1, bytes = 100 * 1024 * 1024, available = 2000 * 1024 * 1024, ok = true }
    st.enqueue_ok, st.enqueue_code, st.enqueue_message, st.enqueue_detail = true, nil, nil, nil
    st.delete_ok, st.delete_code, st.delete_message = true, nil, nil
    st.pause_ok, st.resume_ok, st.retry_ok = true, true, true
    st.retry_code = nil
    st.pause_code = nil
    st.resume_code = nil
    offline = false
    for key, value in pairs(overrides or {}) do st[key] = value end
end

local Cache = setmetatable({}, { __index = RealCache })
function Cache.probe() return st.probe end
function Cache.queueState() return st.queue, st.queue_code end
function Cache.status(chapter_id) return st.statuses[tostring(chapter_id)] end
function Cache.resumePage(chapter_id) return st.resumes[tostring(chapter_id)] end
function Cache.isChapterOpen(chapter_id)
    return st.open_chapter ~= nil and tostring(st.open_chapter) == tostring(chapter_id)
end
function Cache.estimate(entries)
    calls.estimate = entries
    return st.estimate
end
function Cache.enqueue(entries)
    calls.enqueue[#calls.enqueue + 1] = entries
    if st.enqueue_ok then return true end
    return nil, st.enqueue_code, st.enqueue_message, st.enqueue_detail
end
function Cache.delete(ids)
    calls.delete[#calls.delete + 1] = ids
    if st.delete_ok then return true end
    return nil, st.delete_code, st.delete_message
end
function Cache.queuePause()
    calls.pause = calls.pause + 1
    return st.pause_ok, st.pause_code
end
function Cache.queueResume()
    calls.resume = calls.resume + 1
    return st.resume_ok, st.resume_code
end
function Cache.queueRetry(ids)
    calls.retry[#calls.retry + 1] = ids
    return st.retry_ok, st.retry_code
end
package.preload["moonsource_kavita.cache"] = function() return Cache end
package.preload["moonsource_kavita.volume_list"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/volume_list.lua")
end

local VolumeList = require("moonsource_kavita.volume_list")

---@param id integer
---@param title string
---@param pages integer
---@param read integer
---@return table
local function entry(id, title, pages, read)
    return { chapterId = id, volumeId = id, seriesId = 900, libraryId = 1, format = 1,
        title = title, pages = pages, pagesRead = read or 0 }
end

local toc = {
    entry(601, "第 1 卷", 100, 100),
    entry(602, "第 2 卷", 100, 40),
    entry(603, "第 3 卷", 100, 0),
}
local series = { stable_id = "900", title = "测试系列" }

--- 子串断言：Assert.contains 只认数组，文案用这个。
---@param haystack string
---@param needle string
---@param msg string|nil
local function textContains(haystack, needle, msg)
    Assert.is_true(type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
        (msg or "text") .. "：" .. needle .. " 不在 " .. tostring(haystack))
end

--- 打开卷列表；返回 list、选中回调的接收表。
---@return table, table
local function open()
    local picked = {}
    local list = assert(VolumeList.pick(series, toc, function(value) picked.value = value end))
    list:show()
    list:paintTo(Kit.canvas(), 0, 0)
    return list, picked
end

--- 所有行尾按钮（排除标题栏的 left / close）。
---@param list table
---@return table[]
local function tails(list)
    local first = Kit.taps(list)[1]
    local top = first and first.dimen.y or 0
    local out = {}
    for _idx, button in ipairs(Kit.buttons(list)) do
        if button.dimen.y >= top
            and (button.icon == "download" or button.icon == "delete" or button.icon == "refresh"
                or button.icon == "pause" or button.icon == "play_arrow") then
            out[#out + 1] = button
        end
    end
    return out
end

--- 按 04 A9 的路径点一个控件：坐标落在按钮上，事件从窗口一路下发。
---@param list table
---@param widget table
local function tap(list, widget)
    local size = widget.dimen
    local ges = Kit.tap(size.x + math.floor(size.w / 2), size.y + math.floor(size.h / 2))
    ges.ges = "tap"
    list:handleEvent(require("ui/event"):new("Gesture", ges))
end

-- A9：点行尾按钮被按钮吃掉，不关窗、不选中，只弹该卷的确认框。
reset()
st.statuses["601"] = { state = "complete", bytes = 80 * 1024 * 1024 }
local list, picked = open()
local delete_buttons = {}
for _idx, button in ipairs(tails(list)) do
    if button.icon == "delete" then delete_buttons[#delete_buttons + 1] = button end
end
Assert.len(delete_buttons, 1, "只有已缓存的第 1 卷有删除按钮")
local closed_before = #Kit.closed
tap(list, delete_buttons[1])
Assert.eq(#Kit.closed, closed_before, "点行尾按钮不关窗")
Assert.is_nil(picked.value, "点行尾按钮不触发行选中")
local confirm = Themed.last("confirm")
Assert.not_nil(confirm, "删除走确认框")
textContains(confirm.text, "将释放")
textContains(confirm.text, "离线不可读")
Assert.eq(confirm.title, "删除缓存")
confirm.ok_callback()
Assert.eq(calls.delete[1][1], 601, "只删这一卷")

-- 行状态字：已读 · 已缓存 / 在读 / 未缓存；图标各归各位。
st.resumes["602"] = { page = 41, status = "pending" }
list, picked = open()
local text = table.concat(Kit.texts(list), "\n")
textContains(text, "已读 · 已缓存")
textContains(text, "在读 · 待同步")
textContains(text, "未缓存")
local icons = {}
for _idx, button in ipairs(tails(list)) do icons[#icons + 1] = button.icon end
Assert.eq(table.concat(icons, ","), "delete,download,download")

-- 点标题区域仍然是选中（关窗后回调）。
tap(list, Kit.taps(list)[2])
Assert.eq(picked.value and picked.value.chapterId, 602)

reset()
st.statuses["601"] = { state = "stale", bytes = 1 }
st.statuses["602"] = { state = "complete", bytes = 1 }
st.statuses["603"] = { state = "complete", bytes = 1 }
list = open()
text = table.concat(Kit.texts(list), "\n")
textContains(text, "已读 · 已缓存")
textContains(text, "在读 · 已缓存")
textContains(text, "已缓存")
Assert.eq(#tails(list), 3)

-- 标题栏左钮＝缓存整部：只选未缓存（跳过已缓存 / 排队中），先 estimate 再确认。
reset()
st.statuses["601"] = { state = "complete", bytes = 1 }
st.queue = { state = "downloading", entries = { [603] = { chapterId = 603, state = "downloading",
    bytes_done = 50, bytes_total = 100 } }, bytes_done = 50, bytes_total = 100 }
st.estimate = { chapters = 1, bytes = 120 * 1024 * 1024, available = 2000 * 1024 * 1024, ok = true }
list, picked = open()
local title = Kit.buttons(list)[1]
Assert.eq(title.icon, "download", "标题栏左钮是下载图标")
Assert.is_true(title.dimen.y < Kit.taps(list)[1].dimen.y, "左钮在标题栏里，不是行尾")
list.left_callback()
Assert.len(calls.estimate, 1, "先估算")
Assert.eq(calls.estimate[1].chapterId, 602, "只估算未缓存的第 2 卷")
confirm = Themed.last("confirm")
Assert.not_nil(confirm, "估算通过后弹确认框")
Assert.eq(confirm.title, "缓存这一卷")
textContains(confirm.text, "第 2 卷")
textContains(confirm.text, "预计占用 120.0 MB（峰值）")
textContains(confirm.text, "设备可用 2000.0 MB")
textContains(confirm.text, "完成后剩余 1880.0 MB")
Assert.eq(confirm.ok_text, "开始缓存")
confirm.ok_callback()
Assert.len(calls.enqueue, 1)
Assert.eq(calls.enqueue[1][1].chapterId, 602)
local progress = Themed.last("progress_dialog")
Assert.not_nil(progress, "入队后开进度框")
Assert.eq(progress.title, "正在缓存")
Assert.eq(progress.cancel_text, "暂停", "按钮是暂停，不是取消")
Assert.not_nil(progress.on_cancel)
Assert.not_nil(progress.on_background, "后台运行")
Assert.is_true(#calls.retry == 0, "没有失败项就不调 queue_retry")

-- 全部已缓存：不估算，直接 toast。
reset()
for _idx, item_entry in ipairs(toc) do
    st.statuses[tostring(item_entry.chapterId)] = { state = "complete", bytes = 1 }
end
list = open()
local confirms = #Themed.all("confirm")
list.left_callback()
Assert.is_nil(calls.estimate, "没有对象不估算")
textContains(Themed.last("toast").text, "全部已缓存")
Assert.eq(#Themed.all("confirm"), confirms, "全部已缓存不弹框")

-- estimate 说没事可做：toast，不弹框。
reset()
st.estimate = { chapters = 0, bytes = 0, available = 1, ok = false, reason = "nothing_to_do" }
list = open()
list.left_callback()
textContains(Themed.last("toast").text, "全部已缓存或正在下载")
Assert.eq(#Themed.all("confirm"), confirms, "没事可做只 toast")

-- 空间不足：确认框就地换成「空间不足」，主按钮只 toast，不入队。
reset()
st.estimate = { chapters = 3, bytes = 849 * 1024 * 1024, available = 480 * 1024 * 1024, ok = false, reason = "space" }
list = open()
list.left_callback()
confirm = Themed.last("confirm")
Assert.not_nil(confirm)
textContains(confirm.text, "空间不足：需要 849.0 MB，可用 480.0 MB")
Assert.eq(confirm.ok_text, "去清理空间")
confirm.ok_callback()
Assert.len(calls.enqueue, 0, "空间不足不入队")
textContains(Themed.last("toast").text, "空间不足")

-- 低水位：同样不给「开始缓存」。
reset()
st.estimate = { chapters = 3, bytes = 1, available = 400 * 1024 * 1024, ok = false, reason = "low_water" }
list = open()
list.left_callback()
confirm = Themed.last("confirm")
textContains(confirm.text, "可用空间不足（剩余 400.0 MB）")
Assert.eq(confirm.ok_text, "去清理空间")

-- 队列已暂停：确认框要说清「开始缓存会恢复整个队列」（07 A5）。
reset()
st.queue = { state = "paused", pause_reason = "user", entries = {}, bytes_done = 0, bytes_total = 0 }
st.estimate = { chapters = 3, bytes = 10 * 1024 * 1024, available = 2000 * 1024 * 1024, ok = true }
list = open()
list.left_callback()
textContains(Themed.last("confirm").text, "当前下载已暂停，开始缓存会恢复整个队列")

-- 批量里含失败项：入队未缓存的，再逐条重试失败的，进度框算上两项。
reset()
st.statuses["601"] = { state = "complete", bytes = 1 }
st.estimate = { chapters = 1, bytes = 10 * 1024 * 1024, available = 2000 * 1024 * 1024, ok = true }
st.queue = { state = "idle", entries = {
    [602] = { chapterId = 602, state = "failed", bytes_done = 0, bytes_total = 100, last_error = "http 403" },
}, bytes_done = 0, bytes_total = 0 }
list = open()
list.left_callback()
confirm = Themed.last("confirm")
textContains(confirm.text, "另有 1 卷失败将重试")
confirm.ok_callback()
Assert.eq(calls.enqueue[1][1].chapterId, 603)
Assert.eq(calls.retry[1][1], 602)
progress = Themed.last("progress_dialog")
textContains(progress.text, "1/2 卷", "进度框按「入队 + 重试」算总数")

-- 只有失败项：直接给「重试缓存」，文案用 lastError 映射后的说法。
reset()
st.statuses["603"] = { state = "complete", bytes = 1 }
st.queue = { state = "idle", entries = {
    [601] = { chapterId = 601, state = "failed", last_error = "http 403" },
    [602] = { chapterId = 602, state = "failed", last_error = "socket closed" },
}, bytes_done = 0, bytes_total = 0 }
list = open()
list.left_callback()
Assert.is_nil(calls.estimate, "没有要下载的就不估算")
confirm = Themed.last("confirm")
Assert.eq(confirm.title, "重试缓存")
textContains(confirm.text, "服务器拒绝下载（403），检查 API Key / 权限")
textContains(confirm.text, "网络中断或服务器不可达")
confirm.ok_callback()
Assert.eq(table.concat(calls.retry[1], ","), "601,602")
Assert.len(calls.enqueue, 0, "没有未缓存的项就不入队")

return true
