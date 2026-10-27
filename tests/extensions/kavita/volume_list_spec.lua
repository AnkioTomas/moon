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
    local out = {}
    for _idx, button in ipairs(Kit.buttons(list)) do
        if button.icon == "download" or button.icon == "delete" or button.icon == "refresh"
            or button.icon == "pause" or button.icon == "play_arrow" then
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

return true
