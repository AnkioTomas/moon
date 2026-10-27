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

    ---@param entry table
    ---@return table
    local function item(entry)
        if not ctx.show_cache then
            -- unknown_server / 缺 status：回到旧行为，只显示阅读状态（含旧的「已下载」）。
            local mandatory = opts.fallback and opts.fallback(entry) or nil
            return { text = entry.title, value = entry, mandatory = mandatory }
        end
        local model = rowState(ctx, entry)
        local actions = {}
        actions.delete = function()
            confirmDelete(entry, model, function() end)
        end
        return {
            text = entry.title,
            value = entry,
            widget = tailWidget(ctx, entry, model, actions),
        }
    end

    ---@return table[]
    local function items()
        local out = {}
        for _idx, entry in ipairs(toc) do out[#out + 1] = item(entry) end
        return out
    end

    list = require("ui.themes.widgets.list"):new{
        title = series.title or _("选择卷"),
        items = items(),
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
