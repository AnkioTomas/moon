--[[--
Kavita 卷列表：选卷阅读 + 缓存管理（04 A1–A9 / 07 A1–A7）。

一行 = 一卷；点行阅读，行尾「状态字 + 一个图标钮」管该卷的缓存，标题栏左钮开批量预设菜单
（整部 / 从当前进度 / 后 N 卷）。
状态全部在打开 / 每秒轮询时现算：`Cache.status` 是内存索引，`queue_state` 按服务器过滤，
本地已读 / 在读取 toc 的 pagesRead（不按卷调 resume_page，只给有本地进度的行补「待同步」）。

不改 `ui/themes/widgets/list` 与 `row`：行尾控件塞 `item.widget`，靠 KOReader 的
「先子件后自身」事件顺序吃掉点按（04 A9）。批量预设复用主题 `list` 当二级菜单
（04 A9 的 C 变体，ticket 16），不新增控件。

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

--- 目录条目 → 章 id 列表（批量动作的统一取数）。
---@param entries table[]
---@return any[]
local function chapterIds(entries)
    local ids = {}
    for _idx, entry in ipairs(entries or {}) do ids[#ids + 1] = entry.chapterId end
    return ids
end

--- 队列里这一章的条目；缺 queue 能力时用本地入队记忆顶着（只表示「已排队」，没有百分比）。
---@param ctx table
---@param chapter_id any
---@return table|nil
local function queuedEntry(ctx, chapter_id)
    local key = tostring(chapter_id)
    local queued = ctx.entries[key]
    if queued then return queued end
    if not ctx.queue_capable and ctx.pending[key] then return { state = "queued" } end
    return nil
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
---@param memo table|nil 上一次的 resume_page 结果：轮询复用，别每秒为整列扫 journal
---@param pending table<string, boolean>|nil 本地入队记忆：缺 queue 能力时没有别的「排队」来源
---@return table
local function scan(toc, memo, pending)
    local probe = Cache.probe()
    local capabilities = probe.ok and (probe.capabilities or {}) or {}
    local queue_capable = has(capabilities, "queue")
    local queue, queue_code = Cache.queueState()
    -- 能力缺失或这一次读不到队列状态，都只能算「没有可用的队列」：
    -- 不能拿空结果当「都下完了」（02 A4）。
    if not queue_capable or type(queue) ~= "table" then
        queue_capable = false
        queue = nil
    end
    -- unknown_server：缓存状态整块不显示，只剩阅读状态（02 A9）。
    local show_cache = probe.ok and has(capabilities, "status") and queue_code ~= "unknown_server"
    local statuses = {}
    local resumes = memo or {}
    if show_cache then
        for _idx, entry in ipairs(toc) do
            local cid = tostring(entry.chapterId)
            local status = Cache.status(entry.chapterId)
            statuses[cid] = status
            -- 06 A4：只有读过 / 已缓存的行才可能有「待同步」；结果按章记忆，
            -- 每秒轮询不再重复读 journal（false = 查过没有）。
            if resumes[cid] == nil then
                local cached = Cache.isCached(status)
                if cached or readState(entry) ~= nil then
                    resumes[cid] = Cache.resumePage(entry.chapterId) or false
                end
            end
        end
    end
    pending = pending or {}
    -- 缺 queue 时 kamare 的索引已报 complete 才把本地排队记忆撤掉；
    -- 仍排队的继续显示「已排队」，不能假装已经缓存。
    if not queue_capable then
        for cid in pairs(pending) do
            if Cache.isCached(statuses[cid]) then pending[cid] = nil end
        end
    end
    return {
        capabilities = capabilities,
        show_cache = show_cache,
        queue_capable = queue_capable,
        queue = queue,
        entries = queueEntries(queue),
        pending = pending,
        paused = queuePaused(queue),
        statuses = statuses,
        resumes = resumes,
        offline = not online(),
    }
end

--- 一行要显示的状态字与动作；优先级见 04 A2。
---@param ctx table
---@param entry table
---@return table
local function rowState(ctx, entry)
    local cid = tostring(entry.chapterId)
    local queued = queuedEntry(ctx, entry.chapterId)
    local status = ctx.statuses[cid]
    local cached = Cache.isCached(status)
    local read = readState(entry)
    local text, icon
    if queued then
        local percent = entryPercent(queued)
        if ctx.paused and percent then
            text = T(_("已暂停 %1%"), percent)
            icon = "play_arrow"
        elseif queued.state == "failed" then
            text = _("缓存失败")
            icon = "refresh"
        elseif ctx.paused then
            -- 排队还没开始下载就暂停：没有百分比可写。
            text = _("已暂停")
            icon = "play_arrow"
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
    -- 06 A4：kamare 还有位置没推上去（结果由 scan 按章记忆，轮询不重复取）。
    local resume = ctx.resumes[cid]
    local status_code = type(resume) == "table" and resume.status or nil
    if status_code == "pending" or status_code == "failed" then
        text = T(_("%1 · 待同步"), text)
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

--- 删除确认正文（07 A1 / A4 / A6）：释放体积、离线不可读、下载中会取消。
---@param entry table
---@param bytes number|nil
---@param downloading boolean|nil
---@return string
function VolumeList.deleteText(entry, bytes, downloading)
    local text = T(_("删除「%1」的缓存？将释放 %2。"), entry.title, Cache.sizeText(bytes or 0))
    text = text .. "\n" .. _("删除后离线不可读。")
    if downloading then
        text = text .. "\n" .. _("删除会取消这一卷的下载。")
    end
    return text
end

--- 单卷删除确认（04 A6 / 07 A1、A4）。
---@param entry table
---@param model table
---@param done fun()
---@param pending table<string, boolean>|nil 本地入队记忆：删成功后这一卷不再是「已排队」
local function confirmDelete(entry, model, done, pending)
    local Confirm = require("ui.themes.widgets.confirm")
    local bytes = type(model.status) == "table" and tonumber(model.status.bytes)
        or type(model.queued) == "table" and tonumber(model.queued.bytes_done) or 0
    Confirm:new{
        title = _("删除缓存"),
        text = VolumeList.deleteText(entry, bytes, model.queued ~= nil),
        ok_text = _("删除"),
        ok_callback = function()
            local ok, code, message = Cache.delete({ entry.chapterId })
            if ok then
                if pending then pending[tostring(entry.chapterId)] = nil end
            else
                toast(Cache.message(code, message))
            end
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
        local cached = Cache.isCached(status)
        local queued = queuedEntry(ctx, entry.chapterId)
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

--- 批量预设的起点：第一个未读完的卷；全部都读完就退化为整部（ticket 16）。
---@param toc table[]
---@return integer
local function resumeIndex(toc)
    for idx, entry in ipairs(toc) do
        if readState(entry) ~= "read" then return idx end
    end
    return 1
end

--- 从 first 起取 count 卷（缺省到末卷）；越界截断。
---@param toc table[]
---@param first integer
---@param count integer|nil
---@return table[]
local function volumeRange(toc, first, count)
    local out = {}
    local last = count and math.min(#toc, first + count - 1) or #toc
    for idx = first, last do out[#out + 1] = toc[idx] end
    return out
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

--- 暂停原因 → 文案与主按钮（07 A5）。low_space 不给继续。
local PAUSE_REASONS = {
    user = { text = _("已暂停"), resume = true },
    restored = { text = _("已暂停（启动恢复）"), resume = true },
    offline = { text = _("已暂停（断网）"), resume = true },
    wifi = { text = _("已暂停（仅 Wi-Fi 下载）"), resume = true },
    network = { text = _("已暂停（连续下载失败）"), resume = true, retry = true },
    low_space = { text = _("空间不足，已暂停"), resume = false },
}

--- 打开卷列表。返回 list 控件（测试与「部分失败」后重画都要用）。
---@param series Book
---@param toc table[]
---@param cb fun(entry: table)
---@param opts { fallback: fun(entry: table): string|nil }|nil 没有缓存能力时的右侧状态字（旧「已下载」）
---@return table
function VolumeList.pick(series, toc, cb, opts)
    opts = type(opts) == "table" and opts or {}
    -- 缺 queue 能力时没有队列状态可读，只能在本地记「这一卷已经入队」（02 A4）。
    local pending = {}
    local ctx = scan(toc, nil, pending)
    local chosen = false
    local list
    local dialog
    -- 行、重画与确认框互相引用（重画要重建行，行要弹确认框），先声明再赋值。
    local item, items, refresh, confirmRetry, confirmEnqueue, resumeQueue, startProgress, stopPolling

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
        actions.delete = function() confirmDelete(entry, model, refresh, pending) end
        actions.refresh = function() confirmRetry({ entry }) end
        actions.pause = function()
            local ok, code, message = Cache.queuePause()
            -- 队列是全局的：行里的暂停作用于所有服务器的所有下载，明确告诉用户（04 A3）。
            if not ok then toast(Cache.message(code, message)) else toast(_("已暂停整个下载队列")) end
            refresh()
        end
        actions.play_arrow = function() resumeQueue() end
        local offline_uncached = ctx.offline and model.icon == "download"
            and not model.queued and not model.cached
        local row = {
            text = entry.title,
            value = entry,
            widget = tailWidget(ctx, entry, model, actions),
        }
        -- 04 A7：离线未缓存的行仍可点，但只提示；不关窗，用户还能挑别的卷。
        if offline_uncached then
            row.keep_open = true
            row.callback = function() toast(Cache.message("offline_not_cached")) end
        end
        return row
    end

    ---@return table[]
    items = function()
        local out = {}
        for _idx, entry in ipairs(toc) do out[#out + 1] = item(entry) end
        return out
    end

    --- 重画：状态全在 kamare 的内存索引里，重扫一遍即可（列表停在原页）。
    ---@param reuse_resume boolean|nil 轮询用：复用 resume_page 的记忆
    refresh = function(reuse_resume)
        ctx = scan(toc, reuse_resume and ctx.resumes or nil, pending)
        if list and not list.closed then list:setItems(items()) end
    end

    ---@param entries table[]
    ---@return boolean
    local function enqueue(entries)
        local ok, code, message, detail = Cache.enqueue(entries)
        if ok then
            -- 缺 queue 能力时靠这份记忆把行显示成「已排队」（02 A4）。
            for _idx, entry in ipairs(entries) do pending[tostring(entry.chapterId)] = true end
            return true
        end
        toast(Cache.message(code, message, detail))
        return false
    end

    ---@param entries table[]
    ---@return boolean
    local function retry(entries)
        local ids = chapterIds(entries)
        local ok, code, message = Cache.queueRetry(ids)
        if ok then
            for _idx, entry in ipairs(entries) do pending[tostring(entry.chapterId)] = true end
            return true
        end
        toast(Cache.message(code, message))
        return false
    end

    local timer
    local batch

    --- 本批次的条目（按 chapterId 回到 toc）。
    ---@param ids integer[]
    ---@return table[]
    local function batchEntries(ids)
        local out = {}
        for _idx, id in ipairs(ids) do
            for _i, entry in ipairs(toc) do
                if tostring(entry.chapterId) == tostring(id) then out[#out + 1] = entry break end
            end
        end
        return out
    end

    --- 本批次里已经失败的卷（kamare 把失败项留在 entries 里）。
    ---@return table[]
    local function failedEntries()
        local out = {}
        for _idx, entry in ipairs(batch and batchEntries(batch.ids) or {}) do
            local queued = ctx.entries[tostring(entry.chapterId)]
            if type(queued) == "table" and queued.state == "failed" then out[#out + 1] = entry end
        end
        return out
    end

    stopPolling = function()
        if timer then
            require("ui/uimanager"):unschedule(timer)
            timer = nil
        end
    end

    local function closeProgress()
        if dialog and not dialog.closed then dialog:close() end
        dialog = nil
    end

    --- 本服务器范围内的聚合百分比；kamare 的 percent 是 0..1。
    ---@return number
    local function aggregatePercent()
        local percent = tonumber(ctx.queue and ctx.queue.percent)
        if percent then return math.max(0, math.min(100, percent <= 1 and percent * 100 or percent)) end
        local total = tonumber(ctx.queue and ctx.queue.bytes_total) or 0
        local done = tonumber(ctx.queue and ctx.queue.bytes_done) or 0
        if total <= 0 then return 0 end
        return math.max(0, math.min(100, done / total * 100))
    end

    --- 进度框说明行：第几卷 / 共几卷 · 当前卷名。
    ---@return string
    local function progressLine()
        local total = batch and batch.total or 1
        local remaining = 0
        for _idx, id in ipairs(batch and batch.ids or {}) do
            local queued = ctx.entries[tostring(id)]
            if type(queued) == "table" and queued.state ~= "failed" then remaining = remaining + 1 end
        end
        local index = math.max(1, math.min(total, batch and batch.total - remaining + 1 or 1))
        local title
        local current = ctx.queue and ctx.queue.current_chapter_id
        if current ~= nil then
            for _idx, entry in ipairs(toc) do
                if tostring(entry.chapterId) == tostring(current) then title = entry.title break end
            end
        end
        local line = T(_("正在缓存 %1/%2 卷"), index, total)
        return title and T(_("%1 · %2"), line, title) or line
    end

    --- 全部完成 / 只剩失败项：全成 toast，有失败给「部分失败」（04 A5）。
    local function finishDone()
        local failed = failedEntries()
        local total = batch and batch.total or 0
        closeProgress()
        if #failed > 0 then
            local lines = { T(_("%1 卷成功，%2 卷失败"), math.max(0, total - #failed), #failed) }
            for _idx, entry in ipairs(failed) do
                local queued = ctx.entries[tostring(entry.chapterId)]
                local reason = Cache.failureText(type(queued) == "table" and queued.last_error or nil)
                lines[#lines + 1] = T(_("%1：%2"), entry.title, reason or _("缓存失败"))
            end
            local Confirm = require("ui.themes.widgets.confirm")
            Confirm:new{
                title = _("部分失败"),
                text = table.concat(lines, "\n"),
                ok_text = _("查看失败原因"),
                cancel_text = _("关闭"),
                ok_callback = refresh,
            }:show()
        else
            toast(T(_("已缓存 %1 卷"), total))
        end
        batch = nil
    end

    --- 队列暂停：按 pause_reason 给文案与主按钮；low_space 不给继续（07 A5）。
    local function finishPaused()
        local reason = ctx.queue and ctx.queue.pause_reason
        local info = PAUSE_REASONS[reason] or { text = _("已暂停"), resume = true }
        local failed = failedEntries()
        closeProgress()
        local Confirm = require("ui.themes.widgets.confirm")
        Confirm:new{
            title = _("已暂停"),
            text = info.text,
            ok_text = info.resume and (info.retry and _("重试失败项并继续") or _("继续")) or _("去清理空间"),
            cancel_text = _("关闭"),
            ok_callback = function()
                if not info.resume then
                    toast(_("空间不足，已暂停。清理后再下载"))
                    batch = nil
                    return
                end
                if info.retry and #failed > 0 then retry(failed) end
                local ok, code, message = Cache.queueResume()
                if not ok then
                    toast(Cache.message(code, message))
                    return
                end
                local resumed = batch
                batch = nil
                if resumed then startProgress(resumed.ids, resumed.total) end
            end,
            cancel_callback = function() batch = nil end,
        }:show()
    end

    --- 每一拍：重画行，有进度框就更新 / 收尾；队列停住或暂停就不再排下一拍。
    local function tick()
        timer = nil
        -- 没有 queue 能力就没有进度可轮询，也绝不能凭「没有条目」宣布全部完成（02 A4）。
        if not ctx.queue_capable then return end
        refresh(true)
        if dialog then
            if ctx.paused then
                finishPaused()
            elseif not queueRunning(ctx.queue) then
                finishDone()
            else
                dialog:set(progressLine(), aggregatePercent())
            end
        end
        if queueRunning(ctx.queue) and not ctx.paused then
            timer = function()
                timer = nil
                tick()
            end
            require("ui/uimanager"):scheduleIn(1, timer)
        else
            stopPolling()
        end
    end

    --- 进度框：1 秒轮询 queue_state（只看本服务器），后台运行不停队列。
    ---@param ids integer[] 本批次的章 id（入队 + 重试）
    ---@param total integer 本批次的卷数
    startProgress = function(ids, total)
        batch = { ids = ids or {}, total = total or #(ids or {}) }
        local ProgressDialog = require("ui.themes.widgets.progress_dialog")
        -- 缺 queue_control 时只留「后台运行」（02 A4）。
        local control = has(ctx.capabilities, "queue_control")
        dialog = ProgressDialog:new{
            title = _("正在缓存"),
            -- 缺 queue：没有百分比，只报「已排队」（02 A4）。
            text = ctx.queue_capable and T(_("正在缓存 %1/%2 卷"), 1, batch.total) or _("已排队"),
            cancel_text = control and _("暂停") or nil,
            on_cancel = control and function()
                local ok, code, message = Cache.queuePause()
                if not ok then toast(Cache.message(code, message)) end
                refresh()
            end or nil,
            -- 关弹窗 ≠ 取消：队列继续跑，列表行继续按拍刷新（04 A5）。
            on_background = function() dialog = nil end,
        }
        dialog:show()
        refresh(true)
        -- 没有 queue 就没有可轮询的进度；不排拍，也就不会从缺席的队列宣布完成。
        if not ctx.queue_capable then return end
        if not timer then
            timer = function()
                timer = nil
                tick()
            end
            require("ui/uimanager"):scheduleIn(1, timer)
        end
    end

    ---@param entries table[]
    confirmRetry = function(entries)
        local Confirm = require("ui.themes.widgets.confirm")
        Confirm:new{
            title = _("重试缓存"),
            text = retryText(entries, ctx),
            ok_text = _("重试"),
            ok_callback = function()
                if retry(entries) then
                    startProgress(chapterIds(entries), #entries)
                end
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
                local ids = chapterIds(to_enqueue)
                for _idx, id in ipairs(chapterIds(to_retry)) do ids[#ids + 1] = id end
                startProgress(ids, total)
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

    --- 批量入口：三种范围共用 estimate 确认、进度框与失败重试；没有对象只 toast。
    ---@param entries table[]
    local function runBatch(entries)
        local to_enqueue, to_retry = batchTargets(ctx, entries)
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

    --- 「后 N 卷」：正整数才动作；0 / 非数字不动作，越界由 volumeRange 截断。
    local function promptNext()
        local Input = require("ui.themes.widgets.input")
        Input:new{
            title = _("后 N 卷"),
            fields = { { label = _("卷数"), input_type = "number" } },
            callback = function(text)
                local count = math.floor(tonumber(text) or 0)
                if count <= 0 then return end
                runBatch(volumeRange(toc, resumeIndex(toc), count))
            end,
        }:show()
    end

    --- 标题栏左钮：批量缓存预设菜单（04 A9 的 C 变体，复用主题 list 当二级菜单）。
    local function openBatchMenu()
        local Menu = require("ui.themes.widgets.list")
        Menu:new{
            title = _("批量缓存"),
            items = {
                { text = _("缓存整部"), value = "all" },
                { text = _("从当前进度开始"), value = "progress" },
                { text = _("后 N 卷…"), value = "next" },
            },
            on_select = function(value)
                if value == "all" then
                    runBatch(toc)
                elseif value == "progress" then
                    runBatch(volumeRange(toc, resumeIndex(toc), nil))
                else
                    promptNext()
                end
            end,
        }:show()
    end

    local can_batch = ctx.show_cache
        and (has(ctx.capabilities, "enqueue") or has(ctx.capabilities, "queue_control"))

    list = require("ui.themes.widgets.list"):new{
        title = series.title or _("选择卷"),
        items = items(),
        left_icon = can_batch and "download" or nil,
        left_callback = can_batch and openBatchMenu or nil,
        on_select = function(entry)
            chosen = true
            cb(entry)
        end,
        -- 单选点按时先关窗、同一拍再 on_select：下一拍还没选中就是用户关掉了列表。
        close_callback = function()
            -- 04 A8：关列表即停，不设常驻轮询。
            stopPolling()
            require("ui/uimanager"):nextTick(function()
                if not chosen then cb(nil) end
            end)
        end,
    }
    return list
end

return VolumeList
