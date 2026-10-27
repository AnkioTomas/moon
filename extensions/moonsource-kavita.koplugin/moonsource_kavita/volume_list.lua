--[[--
Kavita 卷列表：选卷阅读 + 缓存管理（04 A1–A9 / 07 A1–A7）。

一行 = 一卷；点行阅读，行尾「状态字 + 一个图标钮」管该卷的缓存，标题栏左钮批量缓存整部。
状态全部在打开 / 每秒轮询时现算：`Cache.status` 是内存索引，`queue_state` 按服务器过滤，
本地已读 / 在读取 toc 的 pagesRead（不按卷调 resume_page，只给有本地进度的行补「待同步」）。

不改 `ui/themes/widgets/list` 与 `row`：行尾控件塞 `item.widget`，靠 KOReader 的
「先子件后自身」事件顺序吃掉点按（04 A9）。若该假设不成立，退回 C 变体（二级菜单）。

@module moonsource_kavita.volume_list
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Cache = require("moonsource_kavita.cache")

-- 主题组件一律函数内 require：没有 kamare 的安装（旧「已下载」列表）不该为了加载
-- 这个模块把整套 ui.themes.widgets 拉进来，source.lua 的既有测试也不装它们。

local VolumeList = {}

--- 与 source.lua 的 online() 同口径：系统联网状态。
---@return boolean
local function online()
    return require("ui/network/manager"):isConnected()
end

---@param text string|nil
local function toast(text)
    if not text then return end
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 2 }:show()
end

---@param capabilities table|nil
---@param name string
---@return boolean
local function has(capabilities, name)
    return type(capabilities) == "table" and capabilities[name] == true
end

--- 队列条目按 chapterId 归一成字符串键：kamare 的键可能是数字。
---@param queue table|nil
---@return table
local function queueEntries(queue)
    local out = {}
    for key, entry in pairs(type(queue) == "table" and queue.entries or {}) do
        out[tostring(key)] = entry
    end
    return out
end

--- 队列里还有会自己往前走的项（失败项会留在 entries 里，直到重试）。
---@param queue table|nil
---@return boolean
local function queueRunning(queue)
    for _key, entry in pairs(type(queue) == "table" and queue.entries or {}) do
        if entry.state ~= "failed" then return true end
    end
    return false
end

---@param queue table|nil
---@return boolean
local function queuePaused(queue)
    return type(queue) == "table" and (queue.state == "paused" or queue.pause_reason ~= nil)
end

---@param entry table|nil
---@return integer|nil
local function entryPercent(entry)
    local total = tonumber(entry and entry.bytes_total) or 0
    local done = tonumber(entry and entry.bytes_done) or 0
    if total <= 0 or done <= 0 then return nil end
    return math.floor(done / total * 100)
end

--- 本地阅读状态：已读 / 在读 / nil（与书架百分比同源，不额外调 resume_page）。
---@param entry table
---@return "read"|"reading"|nil
local function readState(entry)
    local pages = tonumber(entry.pages) or 0
    local read = tonumber(entry.pagesRead) or 0
    if pages > 0 and read >= pages then return "read" end
    if read > 0 then return "reading" end
    return nil
end

--- 打开 / 轮询时的一份只读快照。
---@param toc table[]
---@return table
local function scan(toc)
    local probe = Cache.probe()
    local capabilities = probe.ok and (probe.capabilities or {}) or {}
    local queue, queue_code = Cache.queueState()
    if type(queue) ~= "table" then queue = nil end
    -- unknown_server：缓存状态整块不显示，只剩阅读状态（02 A9）。
    local show_cache = probe.ok and has(capabilities, "status") and queue_code ~= "unknown_server"
    local statuses = {}
    if show_cache then
        for _idx, entry in ipairs(toc) do
            statuses[tostring(entry.chapterId)] = Cache.status(entry.chapterId)
        end
    end
    return {
        capabilities = capabilities,
        show_cache = show_cache,
        queue = queue,
        entries = queueEntries(queue),
        paused = queuePaused(queue),
        statuses = statuses,
        offline = not online(),
    }
end

--- 一行要显示的状态字与动作；优先级见 04 A2。
---@param ctx table
---@param entry table
---@return table
local function rowState(ctx, entry)
    local cid = tostring(entry.chapterId)
    local queued = ctx.entries[cid]
    local status = ctx.statuses[cid]
    local cached = status ~= nil and (status.state == "complete" or status.state == "stale")
    local read = readState(entry)
    local text, icon
    if queued then
        local percent = entryPercent(queued)
        if ctx.paused then
            text = percent and T(_("已暂停 %1%"), percent) or _("已暂停")
            icon = "play_arrow"
        elseif queued.state == "failed" then
            text = _("缓存失败")
            icon = "refresh"
        else
            text = percent and T(_("下载中 %1%"), percent) or _("已排队")
            icon = "pause"
        end
    elseif cached then
        local base = read == "read" and _("已读") or read == "reading" and _("在读")
        text = base and T(_("%1 · 已缓存"), base) or _("已缓存")
        icon = "delete"
    else
        local base = read == "read" and _("已读") or read == "reading" and _("在读") or _("未缓存")
        text = ctx.offline and T(_("%1 · 离线"), base) or base
        icon = "download"
    end
    -- 06 A4：kamare 还有位置没推上去。只有本地读过（或有缓存）的行才可能有，
    -- 因此只为这些行取一次 resume_page，不给整列付 N 次调用。
    if ctx.show_cache and (read ~= nil or cached) then
        local resume = Cache.resumePage(entry.chapterId)
        local status_code = type(resume) == "table" and resume.status or nil
        if status_code == "pending" or status_code == "failed" then
            text = T(_("%1 · 待同步"), text)
        end
    end
    return { text = text, icon = icon, queued = queued, status = status, read = read, cached = cached }
end

--- 图标钮：40×40 逻辑像素的触摸区。禁用态仍要能点出解释（置灰 + toast），
--- 所以只把外观交给 Button 的 enabled，点按另接一个回调。
---@param icon string
---@param callback fun()|nil
---@param disabled_tap fun()|nil
---@return table
local function actionButton(icon, callback, disabled_tap)
    local Button = require("ui.themes.widgets.button")
    local Theme = require("ui.themes")
    local button = Button:new{
        icon = icon, variant = "ghost",
        width = Theme.px(40), height = Theme.px(40),
        enabled = disabled_tap == nil,
        callback = callback,
    }
    if disabled_tap then
        button.onTapThemeButton = function()
            disabled_tap()
            return true
        end
    end
    return button
end

--- 行尾控件：状态字 + 动作钮。给了 widget 就不再传 mandatory（list.lua 的约定）。
---@param ctx table
---@param entry table
---@param model table
---@param actions table
---@return table
local function tailWidget(ctx, entry, model, actions)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local Text = require("ui.themes.widgets.text")
    local group = HorizontalGroup:new{ align = "center" }
    group[#group + 1] = Text.line("caption", model.text)
    local icon = model.icon
    local enabled = true
    local disabled_tap
    if icon == "download" then
        enabled = has(ctx.capabilities, "enqueue")
        if enabled then
            icon = "download"
        end
    elseif icon == "delete" then
        enabled = has(ctx.capabilities, "delete")
        if enabled and Cache.isChapterOpen(entry.chapterId) then
            enabled = false
            disabled_tap = function()
                toast(Cache.message("chapter_open"))
            end
        end
    elseif icon == "refresh" or icon == "pause" or icon == "play_arrow" then
        enabled = has(ctx.capabilities, "queue_control")
    end
    if enabled then
        group[#group + 1] = actionButton(icon, actions[icon])
    elseif disabled_tap then
        group[#group + 1] = actionButton(icon, nil, disabled_tap)
    end
    return group
end

--- 单卷删除确认（04 A6 / 07 A1、A4）。
---@param entry table
---@param model table
---@param done fun()
local function confirmDelete(entry, model, done)
    local Confirm = require("ui.themes.widgets.confirm")
    local bytes = type(model.status) == "table" and tonumber(model.status.bytes)
        or type(model.queued) == "table" and tonumber(model.queued.bytes_done) or 0
    local text = T(_("删除「%1」的缓存？将释放 %2。"), entry.title, Cache.sizeText(bytes))
    text = text .. "\n" .. _("删除后离线不可读。")
    if model.queued then
        text = text .. "\n" .. _("删除会取消这一卷的下载。")
    end
    Confirm:new{
        title = _("删除缓存"),
        text = text,
        ok_text = _("删除"),
        ok_callback = function()
            local ok, code, message = Cache.delete({ entry.chapterId })
            if not ok then toast(Cache.message(code, message)) end
            done()
        end,
    }:show()
end

--- 卷名清单：≤3 卷列全名，多了只写第一卷 + 总数。
---@param entries table[]
---@return string
local function namesText(entries)
    if #entries <= 3 then
        local names = {}
        for _idx, entry in ipairs(entries) do names[#names + 1] = entry.title end
        return table.concat(names, "、")
    end
    return T(_("%1 等 %2 卷"), entries[1].title, #entries)
end

--- 「缓存整部」的对象：未缓存未排队的入队；队列里失败的走 queue_retry
--- （07 A4；enqueue 对仍在队里的失败项只会回 already_queued）。
---@param ctx table
---@param toc table[]
---@return table[] enqueue, table[] retry
local function batchTargets(ctx, toc)
    local enqueue, retry = {}, {}
    for _idx, entry in ipairs(toc) do
        local cid = tostring(entry.chapterId)
        local status = ctx.statuses[cid]
        local cached = type(status) == "table" and (status.state == "complete" or status.state == "stale")
        local queued = ctx.entries[cid]
        if not cached then
            if queued then
                if queued.state == "failed" then retry[#retry + 1] = entry end
            else
                enqueue[#enqueue + 1] = entry
            end
        end
    end
    return enqueue, retry
end

--- 批量确认框正文：卷数 / 卷名 / 峰值 / 可用 / 完成后剩余（04 A4 + 07 A6）。
---@param entries table[] 要入队的卷
---@param estimate table Cache.estimate 结果
---@param retry_count integer
---@param paused boolean
---@return string
local function enqueueText(entries, estimate, retry_count, paused)
    local lines = { T(_("将缓存：%1"), namesText(entries)) }
    lines[#lines + 1] = T(_("预计占用 %1（峰值）"), Cache.sizeText(estimate.bytes))
    lines[#lines + 1] = T(_("设备可用 %1"), Cache.sizeText(estimate.available))
    local left = (tonumber(estimate.available) or 0) - (tonumber(estimate.bytes) or 0)
    lines[#lines + 1] = T(_("完成后剩余 %1"), Cache.sizeText(math.max(0, left)))
    if retry_count > 0 then lines[#lines + 1] = T(_("另有 %1 卷失败将重试"), retry_count) end
    -- 07 A5：enqueue 会隐式恢复整条队列，先讲清楚。
    if paused then lines[#lines + 1] = _("当前下载已暂停，开始缓存会恢复整个队列") end
    return table.concat(lines, "\n")
end

--- 重试确认框正文：逐条 lastError 用 07 A7 的表映射，不显示原始堆栈。
---@param entries table[]
---@param ctx table
---@return string
local function retryText(entries, ctx)
    local lines = { T(_("将重试：%1"), namesText(entries)) }
    for _idx, entry in ipairs(entries) do
        local queued = ctx.entries[tostring(entry.chapterId)]
        local reason = Cache.failureText(type(queued) == "table" and queued.last_error or nil)
        if reason then lines[#lines + 1] = T(_("%1：%2"), entry.title, reason) end
    end
    return table.concat(lines, "\n")
end

--- 空间不足：就地换成清理提示，主按钮只 toast（07 A6）。
---@param message string
local function confirmSpace(message)
    local Confirm = require("ui.themes.widgets.confirm")
    Confirm:new{
        title = _("空间不足"),
        text = message .. "\n" .. _("清理后再下载"),
        ok_text = _("去清理空间"),
        ok_callback = function() toast(message) end,
    }:show()
end

--- 打开卷列表。返回 list 控件（测试与「部分失败」后重画都要用）。
---@param series Book
---@param toc table[]
---@param cb fun(entry: table)
---@param opts { fallback: fun(entry: table): string|nil }|nil 没有缓存能力时的右侧状态字（旧「已下载」）
---@return table
function VolumeList.pick(series, toc, cb, opts)
    opts = type(opts) == "table" and opts or {}
    local ctx = scan(toc)
    local chosen = false
    local list
    local dialog
    -- 行、重画与确认框互相引用（重画要重建行，行要弹确认框），先声明再赋值。
    local item, items, refresh, confirmRetry, confirmEnqueue, resumeQueue

    ---@param entry table
    ---@return table
    item = function(entry)
        if not ctx.show_cache then
            -- unknown_server / 缺 status：回到旧行为，只显示阅读状态（含旧的「已下载」）。
            local mandatory = opts.fallback and opts.fallback(entry) or nil
            return { text = entry.title, value = entry, mandatory = mandatory }
        end
        local model = rowState(ctx, entry)
        local actions = {}
        actions.download = function() confirmEnqueue({ entry }, {}) end
        actions.delete = function() confirmDelete(entry, model, refresh) end
        actions.refresh = function() confirmRetry({ entry }) end
        actions.pause = function()
            local ok, code, message = Cache.queuePause()
            if not ok then toast(Cache.message(code, message)) end
            refresh()
        end
        actions.play_arrow = function() resumeQueue() end
        return {
            text = entry.title,
            value = entry,
            widget = tailWidget(ctx, entry, model, actions),
        }
    end

    ---@return table[]
    items = function()
        local out = {}
        for _idx, entry in ipairs(toc) do out[#out + 1] = item(entry) end
        return out
    end

    --- 重画：状态全在 kamare 的内存索引里，重扫一遍即可（列表停在原页）。
    refresh = function()
        ctx = scan(toc)
        if list and not list.closed then list:setItems(items()) end
    end

    ---@param entries table[]
    ---@return boolean
    local function enqueue(entries)
        local ok, code, message, detail = Cache.enqueue(entries)
        if ok then return true end
        toast(Cache.message(code, message, detail))
        return false
    end

    ---@param entries table[]
    ---@return boolean
    local function retry(entries)
        local ids = {}
        for _idx, entry in ipairs(entries) do ids[#ids + 1] = entry.chapterId end
        local ok, code, message = Cache.queueRetry(ids)
        if ok then return true end
        toast(Cache.message(code, message))
        return false
    end

    --- 进度框：1 秒轮询与三种收尾见 reap()。
    ---@param total integer 本批次的卷数（入队 + 重试）
    local function startProgress(total)
        local ProgressDialog = require("ui.themes.widgets.progress_dialog")
        dialog = ProgressDialog:new{
            title = _("正在缓存"),
            text = T(_("正在缓存 %1/%2 卷"), 1, total),
            cancel_text = _("暂停"),
            on_cancel = function()
                local ok, code, message = Cache.queuePause()
                if not ok then toast(Cache.message(code, message)) end
                dialog = nil
                refresh()
            end,
            on_background = function() dialog = nil end,
        }
        dialog:show()
        refresh()
    end

    ---@param entries table[]
    confirmRetry = function(entries)
        local Confirm = require("ui.themes.widgets.confirm")
        Confirm:new{
            title = _("重试缓存"),
            text = retryText(entries, ctx),
            ok_text = _("重试"),
            ok_callback = function()
                if retry(entries) then startProgress(#entries) end
            end,
        }:show()
    end

    --- 先 estimate 再画 04 A4 的确认框；空间不足就地换文案（07 A6）。
    ---@param to_enqueue table[]
    ---@param to_retry table[]
    confirmEnqueue = function(to_enqueue, to_retry)
        local estimate, code, message = Cache.estimate(to_enqueue)
        if type(estimate) ~= "table" then
            toast(Cache.message(code, message))
            return
        end
        local reason = Cache.estimateMessage(estimate)
        if reason then
            if estimate.reason == "nothing_to_do" then toast(reason) else confirmSpace(reason) end
            return
        end
        local count = tonumber(estimate.chapters) or #to_enqueue
        local total = count + #to_retry
        local Confirm = require("ui.themes.widgets.confirm")
        Confirm:new{
            title = total == 1 and _("缓存这一卷") or T(_("缓存 %1 卷"), total),
            text = enqueueText(to_enqueue, estimate, #to_retry, ctx.paused),
            ok_text = _("开始缓存"),
            ok_callback = function()
                if not enqueue(to_enqueue) then return end
                if #to_retry > 0 then retry(to_retry) end
                startProgress(total)
            end,
        }:show()
    end

    --- 恢复队列：低水位不给继续，连续失败先逐条重试失败项（07 A5）。
    resumeQueue = function()
        local reason = type(ctx.queue) == "table" and ctx.queue.pause_reason or nil
        if reason == "low_space" then
            toast(_("空间不足，已暂停。清理后再下载"))
            return
        end
        if reason == "network" then
            local failed = {}
            for _idx, entry in ipairs(toc) do
                local queued = ctx.entries[tostring(entry.chapterId)]
                if type(queued) == "table" and queued.state == "failed" then failed[#failed + 1] = entry end
            end
            if #failed > 0 then retry(failed) end
        end
        local ok, code, message = Cache.queueResume()
        if not ok then toast(Cache.message(code, message)) end
        refresh()
    end

    --- 标题栏左钮「缓存整部」：没有对象就只 toast。
    local function batch()
        local to_enqueue, to_retry = batchTargets(ctx, toc)
        if #to_enqueue == 0 and #to_retry == 0 then
            toast(_("全部已缓存"))
            return
        end
        if #to_enqueue == 0 then
            confirmRetry(to_retry)
            return
        end
        confirmEnqueue(to_enqueue, to_retry)
    end

    local can_batch = ctx.show_cache
        and (has(ctx.capabilities, "enqueue") or has(ctx.capabilities, "queue_control"))

    list = require("ui.themes.widgets.list"):new{
        title = series.title or _("选择卷"),
        items = items(),
        left_icon = can_batch and "download" or nil,
        left_callback = can_batch and batch or nil,
        on_select = function(entry)
            chosen = true
            cb(entry)
        end,
        -- 单选点按时先关窗、同一拍再 on_select：下一拍还没选中就是用户关掉了列表。
        close_callback = function()
            require("ui/uimanager"):nextTick(function()
                if not chosen then cb(nil) end
            end)
        end,
    }
    return list
end

return VolumeList
