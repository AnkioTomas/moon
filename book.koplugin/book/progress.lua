--[[--
阅读进度：输出 ProgressPosition，经 Source 拉/推。
本地进度写入 pending_progress；上传仅处理未同步行。

@module koplugin.book.book.progress
--]]

--- 统一阅读位置（拉/推进度唯一形态）。
---@class ProgressPosition
---@field fraction number 全书比例 0..1，必填
---@field chapter_idx integer|nil 连续章序号（1-based）；部分源没有
---@field chapter_title string|nil 当前章节标题（跨源可读，不依赖 idx）
---@field chapter_fraction number|nil 章内比例 0..1
---@field page integer|nil 当前文档页码（1-based）
---@field total_pages integer|nil 当前文档总页数
---@field locator string|nil XPointer/CFI 等精确定位
---@field extra table|nil 源私有定位字段，原样往返本地库；跨源代码不得解读其内容
---@field updated_at integer|nil 进度/阅读最后活跃时间（含远端 readUpdateTime）

local logger = require("utils.log")
local ProgressDB = require("db.progress")
local Position = require("book.progress.position")
local Text = require("utils.text")
local T = require("ffi/util").template
local _ = require("gettext")

local Progress = {
    asked_conflicts = {},
    last_revision = 0,
    sync_runs = {},
}

--- fraction 钳制到 0..1。
---@return number
function Progress.clampFraction(raw)
    local n = tonumber(raw)
    if not n then
        return 0
    end
    if n > 1 and n <= 100 then
        n = n / 100
    end
    if n < 0 then
        return 0
    end
    if n > 1 then
        return 1
    end
    return n
end

--- 百分比钳制到 0..100 整数。
--- as_frac 或 (0,1) 区间值按比例换算；finished 为真且未满则抬到 100。
---@param raw any 原始进度（百分数或 0..1 比例）
---@param finished boolean|nil 是否已读完
---@param as_frac boolean|nil 强制按 0..1 比例解释
---@return number
function Progress.clampPercent(raw, finished, as_frac)
    local n = tonumber(raw) or 0
    if as_frac or (n > 0 and n < 1) then
        n = n * 100
    end
    n = math.floor(n + 0.5)
    if n < 0 then
        n = 0
    elseif n > 100 then
        n = 100
    end
    if finished and n < 100 then
        return 100
    end
    return n
end

--- 生成单调递增的进度修订号（同一进程内不会重复）。
--- 秒级时间戳在同一秒内多次写入会撞号，而修订号是 pending_progress 判定新旧的
--- 依据，必须严格递增。
---@return integer
local function nextRevision()
    Progress.last_revision = math.max(os.time(), Progress.last_revision + 1)
    return Progress.last_revision
end

--- 当前 ProgressPosition；位置完全来自 ReaderSession 快照。
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
function Progress.position(snapshot)
    local Session = require("ui.reader.session")
    local Toc = require("ui.reader.session.toc")
    local position = Position.position(snapshot, Toc.list(snapshot), Session.chapterTitle(snapshot))
    if position.chapter_idx then
        position.chapter_fraction = Toc.chapterFraction(snapshot) or position.chapter_fraction
    end
    return position
end

--- 把跳转结果落到 sidecar，让原生阅读器下次开书就在这个位置。
---
--- 只写打开中的 ``ui.doc_settings``：``DocSettings:open`` 每次都从磁盘新建实例，
--- 另开一份写盘会在关书 flush 时被 ReaderUI 那份整体覆盖。
---@param ui table
---@param pct number 已 clamp 的文档内比例
local function saveDocSettings(ui, pct)
    local settings = ui.doc_settings
    if not settings then return end
    settings:saveSetting("percent_finished", pct)
    if ui.rolling and ui.rolling.xpointer then
        settings:saveSetting("last_xpointer", ui.rolling.xpointer)
    elseif ui.paging and ui.view then
        settings:saveSetting("last_page", ui.view.state and ui.view.state.page)
    end
    settings:flush()
end

--- 精确定位：rolling 文档的 XPointer。跳转成功返回 true。
---
--- 必须先验 ``isXPointerInDocument``：换源、换版本或章节文件变了之后，
--- 旧 XPointer 会把读者扔到文档里一个毫不相干的位置。
---@param ui table
---@param locator string|nil
---@return boolean
local function gotoLocator(ui, locator)
    if type(locator) ~= "string" or locator == "" then return false end
    local doc = ui.document
    if not doc or not doc.isXPointerInDocument then return false end
    local ok, inside = pcall(doc.isXPointerInDocument, doc, locator)
    if not ok or not inside then return false end
    if ui.rolling then
        ui.rolling:onGotoXPointer(locator)
    elseif ui.link then
        ui.link:onGotoXPointer(locator)
    else
        return false
    end
    return true
end

--- 精确定位：固定版式的页码。跳转成功返回 true。
---
--- 只有总页数与记录时一致才认页码：重新排版后同一个页码是另一个位置。
---@param ui table
---@param pos ProgressPosition|nil
---@return boolean
local function gotoPage(ui, pos)
    local page = pos and tonumber(pos.page)
    local recorded_total = pos and tonumber(pos.total_pages)
    local doc = ui.document
    if not page or not recorded_total or not doc or not doc.getPageCount then return false end
    local total = doc:getPageCount()
    if not total or total ~= recorded_total or page < 1 or page > total then return false end
    local Event = require("ui/event")
    ui:handleEvent(Event:new("GotoPage", math.floor(page)))
    return true
end

--- 把一个位置应用到当前文档，并同步落 sidecar。
---
--- 按精度降级：XPointer > 页码 > 比例。比例会随字号、边距、字体变化漂移，
--- 同一本书在两台设备上算出的比例根本对不齐，所以它只是最后的兜底手段。
---@param ui table
---@param pos ProgressPosition|nil 位置；缺精确坐标时退回 pct
---@param pct number 文档内比例，最后手段
local function applyPosition(ui, pos, pct)
    pct = Progress.clampFraction(pct)
    if not gotoLocator(ui, pos and pos.locator) and not gotoPage(ui, pos) then
        local doc = ui.document
        if doc and doc.getXPointerFromProportion then
            local xptr = doc:getXPointerFromProportion(pct)
            if xptr and ui.rolling then
                ui.rolling:onGotoXPointer(xptr)
            elseif xptr and ui.link then
                ui.link:onGotoXPointer(xptr)
            end
        elseif doc and doc.getPageCount then
            local total = doc:getPageCount() or 1
            local page = math.max(1, math.min(total, math.floor(pct * total + 0.5)))
            local Event = require("ui/event")
            ui:handleEvent(Event:new("GotoPage", page))
        else
            return
        end
    end
    saveDocSettings(ui, pct)
end

--- 冷打开：pending 章序号与当前身份一致时恢复章内位置。
--- 同章才敢用 locator——它是章节文件内的坐标，跨章无意义。
---@param snapshot ReaderSessionSnapshot
function Progress.applyLocalPending(snapshot)
    local id = snapshot and snapshot.identity
    if not id or not id.chapter_idx or not snapshot.ui then return end
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row or tonumber(row.chapter_idx) ~= tonumber(id.chapter_idx) then return end
    if row.locator == nil and row.chapter_fraction == nil then return end
    applyPosition(snapshot.ui, row, row.chapter_fraction or 0)
end

--- 服务端确认后标记对应本地版本已同步；新版本不会被旧回调覆盖。
---@param source_id string
---@param stable_id string
---@param revision integer
---@param done fun(ok: boolean)
local function confirm(source_id, stable_id, revision, done)
    local ok = ProgressDB.markSynced(source_id, stable_id, revision)
    -- 未命中说明推送期间又写了更新的版本（心跳/再翻页）或行已不在：不是错误，
    -- 新版本留给下次推送即可，降级为 dbg。
    if not ok then logger.dbg("book.progress confirm superseded", stable_id) end
    done(ok)
end

--- 保存当前文档进度。写入完成前不发网络请求，避免同步旧快照。
---@param snapshot ReaderSessionSnapshot
---@param cb fun(ok: boolean)|nil
function Progress.save(snapshot, cb)
    local id = snapshot and snapshot.identity
    if not id or not id.source_id or not id.stable_id then
        if cb then cb(false) end
        return
    end
    local pos = Progress.position(snapshot)
    local previous = ProgressDB.get(id.source_id, id.stable_id)
    local previous_extra = previous and previous.extra
    local previous_idx = previous_extra and tonumber(previous_extra.chapter_idx)
    if previous_idx and previous_idx == tonumber(pos.chapter_idx) then
        -- position 只包含通用阅读坐标；同章时保留源侧不透明 extra，
        -- 避免保存本地进度时丢失远端桥接坐标。
        pos.extra = previous_extra
    end
    pos.updated_at = nextRevision()
    local ok = ProgressDB.upsert(id.source_id, id.stable_id, pos)
    if not ok then logger.warn("book.progress save failed", id.stable_id) end
    if cb then cb(ok) end
end

---@param row PendingProgress
---@return ProgressPosition
local function rowPosition(row)
    return {
        fraction = row.fraction,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        chapter_fraction = row.chapter_fraction,
        page = row.page,
        total_pages = row.total_pages,
        locator = row.locator,
        extra = row.extra,
    }
end

--- 将一个 Source 的本地脏进度推到远端。Pull 只走 Progress.pull（开书冲突 UI）。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
local progressDiffers -- 前向声明：定义在文件后段，syncOnce 的重连冲突检查要用
local isSameBook -- 前向声明：同上，判断是否「当前正在阅读的书」
local spineCmp -- 前向声明：同上，页级源按 spine/元素路径比较方向
local docFragmentIndex -- 前向声明：同上，取 xpointer 里的 spine 序号
local function syncOnce(source, opts, cb)
    opts = opts or {}
    local target = opts.identity and opts.identity.stable_id or "all"
    local can_push = source and type(source.putProgressAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    logger.dbg("book.progress sync start", source and source.id or "none", target,
        opts.dirty_only and "dirty_only" or "full")
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    local function finish(value, err)
        if cancelled then return end
        if value then
            logger.dbg("book.progress sync done", source and source.id or "none", target,
                "pulled", value.pulled or 0, "pushed", value.pushed or 0,
                "conflicts", value.conflicts or 0)
        else
            logger.warn("book.progress sync failed", source and source.id or "none", target, err)
        end
        if cb then cb(value, err) end
    end
    if not source or not can_push then
        require("ui/uimanager"):nextTick(function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end)
        return { cancel = function() cancelled = true end }
    end

    local identities, seen = {}, {}
    --- 把一个待同步身份加入队列，按 (stable_id, chapter_idx) 去重。
    ---@param source_id string
    ---@param stable_id string|nil 空串与 nil 直接忽略
    ---@param chapter_idx integer|nil nil 表示整本书
    local function add(source_id, stable_id, chapter_idx)
        local key = tostring(stable_id) .. "\31" .. tostring(chapter_idx or 0)
        if stable_id and stable_id ~= "" and not seen[key] then
            seen[key] = true
            identities[#identities + 1] = {
                source_id = source_id, stable_id = stable_id, chapter_idx = chapter_idx,
            }
        end
    end
    if opts.identity then
        add(source.id, opts.identity.stable_id, opts.identity.chapter_idx)
    elseif not opts.dirty_only then
        for _, stable_id in ipairs(require("db.book").libraryStableIdsBySource(source.id)) do
            add(source.id, stable_id)
        end
    end
    if not opts.identity then
        for _, row in ipairs(ProgressDB.unsynced(source.id)) do
            add(source.id, row.stable_id, row.chapter_idx)
        end
    end

    local index = 1
    local nextIdentity
    -- 批量重连一轮里最多只弹一次冲突：避免离线读多本后联网时弹一屏 ConfirmBox。
    local conflict_asked = false
    --- 推送一条脏进度（本地优先落地）。
    ---@param identity table
    ---@param row table
    local function doPush(identity, row)
        current_job = source:putProgressAsync(identity, rowPosition(row), function(ok, err)
            current_job = nil
            if cancelled then return end
            if ok ~= true then
                if opts.dirty_only then
                    result.push_error = err or "progress push failed"
                    logger.warn("book.progress push failed; keep dirty", source.id, identity.stable_id, result.push_error)
                    nextIdentity()
                    return
                end
                finish(nil, err or "progress push failed")
                return
            end
            confirm(source.id, identity.stable_id, row.updated_at, function(confirmed)
                -- 未命中只说明本地又有更新版本，不是失败：本轮不计数，新版本下次再推。
                if confirmed then result.pushed = result.pushed + 1 end
                nextIdentity()
            end)
        end)
    end

    --- 推之前先拉云端比对；冲突时**不静默覆盖云端，也不静默改本地**。
    --- silent（关书/suspend 推送）：云端更靠后/已读完 → **当场弹窗**让用户选（本地/云端）；
    --- 本地不落后 → 推本地。
    --- 非 silent（批量重连）：只对「当前正在阅读的那本」弹一次；其余留脏，等用户读到再谈。
    ---@param identity table
    ---@param row table
    ---@param silent boolean|nil
    local function pushChecked(identity, row, silent)
        local local_pos = rowPosition(row)
        local settled = false
        local function proceed()
            if settled then return end
            settled = true
            doPush(identity, row)
        end
        local job = source:getProgressAsync(identity, function(remote, _err, meta)
            if cancelled or settled then return end
            local empty = type(meta) == "table" and meta.empty
            local page_level = type(meta) == "table" and meta.page_level == true
            -- 页级源只比 spine/元素路径（不用百分比）；取不到 spine 才退回通用判定。
            local cmp
            if remote and not empty and page_level then
                cmp = spineCmp(local_pos, remote)
            end
            local conflict
            if cmp ~= nil then
                conflict = cmp ~= 0
            else
                conflict = remote and not empty
                    and progressDiffers(local_pos, remote, identity, nil, page_level)
            end
            if not conflict then
                proceed()
                return
            end
            settled = true
            if silent then
                -- 关书/suspend 推送：本地不落后 → 直接推（推进云端，安全）。
                -- 云端更靠后/已读完 → 冲突，**当场弹窗**让用户选，不推本地也不静默采纳、
                -- 更不留到下次开书。关书时 Session 可能已清空，不能再依赖 isSameBook。
                --
                -- 页级源的「更靠后」按 spine 判定：同 spine 内元素级的先后只是视口取整
                -- 噪声（Kavita 的 pageNum 本就是 spine 级），若拿来判冲突，用户刚选云端
                -- 跳转、立刻关书时会因取整再弹一次假冲突。与开书 pull 的同 spine 处理一致。
                local remote_ahead
                if page_level then
                    local local_spine = docFragmentIndex(local_pos and local_pos.locator)
                    local remote_spine = docFragmentIndex(remote and remote.locator)
                    if local_spine and remote_spine then
                        remote_ahead = remote_spine > local_spine
                            or (tonumber(remote and remote.fraction) or 0) >= 1
                    else
                        remote_ahead = cmp == 1 or (tonumber(remote and remote.fraction) or 0) >= 1
                    end
                else
                    remote_ahead = cmp == 1 or (tonumber(remote and remote.fraction) or 0) >= 1
                end
                if not remote_ahead then
                    doPush(identity, row)
                    nextIdentity()
                    return
                end
                logger.dbg("book.progress push conflict prompt (remote ahead)", identity.stable_id)
                Progress.askReconnectConflict(source, identity, local_pos, remote, function(choice)
                    if cancelled then return end
                    if choice == "cloud" then
                        ProgressDB.adoptRemote(source.id, identity.stable_id, rowPosition(remote))
                        nextIdentity()
                    else
                        doPush(identity, row)
                    end
                end)
                return
            end
            if conflict_asked or not isSameBook(identity) then
                -- 本轮已问过，或冲突的不是当前在读的书：不弹、也不推（否则会覆盖云端），
                -- 行保持脏，等用户真的去读它时由 Progress.pull 再谈。
                logger.dbg("book.progress reconnect conflict deferred", identity.stable_id)
                nextIdentity()
                return
            end
            conflict_asked = true
            Progress.askReconnectConflict(source, identity, local_pos, remote, function(choice)
                if cancelled then return end
                if choice == "cloud" then
                    ProgressDB.adoptRemote(source.id, identity.stable_id, rowPosition(remote))
                    nextIdentity()
                else
                    doPush(identity, row)
                end
            end)
        end)
        if not job then proceed() end
    end

    --- 处理队列里的下一个身份：本地脏行先做冲突检查再推；队列空即 finish。从不全量 pull。
    nextIdentity = function()
        if cancelled then return end
        local identity = identities[index]
        index = index + 1
        if not identity then finish(result); return end

        local row = ProgressDB.get(source.id, identity.stable_id)
        if row and row.sync_status == 0 then
            if opts.force or type(source.getProgressAsync) ~= "function" then
                -- force：用户在冲突弹窗里明确选了「本地」，本地位置直接盖云端，不再比对。
                doPush(identity, row)
            else
                -- identity（关书/开书推送）走 silent：冲突留脏不弹；批量重连才弹/延后。
                pushChecked(identity, row, opts.identity ~= nil)
            end
            return
        end
        nextIdentity()
    end
    require("ui/uimanager"):nextTick(nextIdentity)
    return { cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end }
end

--- 合并完全相同的重入同步；不同书籍/模式仍各自执行，不能混用结果。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean, force?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Progress.syncAsync(source, opts, cb)
    opts = opts or {}
    local identity = opts.identity
    local key = table.concat({
        source.id,
        tostring(identity and identity.stable_id or "all"),
        tostring(identity and identity.chapter_idx or 0),
        opts.dirty_only and "dirty" or "full",
        opts.force and "force" or "push",
    }, "\31")
    local subscriber = { active = true, cb = cb }
    local run = Progress.sync_runs[key]
    if run then
        run.subscribers[#run.subscribers + 1] = subscriber
    else
        run = { subscribers = { subscriber } }
        Progress.sync_runs[key] = run
        run.job = syncOnce(source, opts, function(result, err)
            if Progress.sync_runs[key] == run then Progress.sync_runs[key] = nil end
            for _, item in ipairs(run.subscribers) do
                if item.active and item.cb then item.cb(result, err) end
            end
        end)
    end
    return { cancel = function()
            if not subscriber.active then return end
            subscriber.active = false
            for _, item in ipairs(run.subscribers) do
                if item.active then return end
            end
            if Progress.sync_runs[key] == run then
                Progress.sync_runs[key] = nil
                if run.job and run.job.cancel then run.job.cancel() end
            end
        end }
end

--- 异步进度回调是否仍对同一本书有效（不比 chapter_idx，避免切章后丢弃拉取结果）。
---@param id BookIdentity|nil
---@return boolean
isSameBook = function(id)
    local current = require("ui.reader.session").current()
    local cur = current and current.identity
    return cur ~= nil and id ~= nil
        and cur.source_id == id.source_id
        and cur.stable_id == id.stable_id
end

--- 当前会话可用的章节目录（优先阅读快照，不依赖 Store.toc 是否已落库）。
--- 阅读形态由物理身份决定：带 ``chapter_idx`` 才算按章（book 源的多卷系列也适用）。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
local function chapterToc(id, snapshot)
    if not id or not id.chapter_idx then
        return nil
    end
    local Session = require("ui.reader.session")
    local snap = snapshot or Session.current()
    if not snap or not snap.identity then
        return nil
    end
    if snap.identity.source_id ~= id.source_id or snap.identity.stable_id ~= id.stable_id then
        return nil
    end
    local toc = require("ui.reader.session.toc").list(snap)
    if type(toc) == "table" and #toc > 0 then
        return toc
    end
    return nil
end

--- xpointer 里的 `DocFragment[D]`（= spine+1）；无返回 nil。
--- 页级源（Kavita）用它把本地位置与远端 pageNum 对齐到同一 spine。
---@param locator string|nil
---@return integer|nil
docFragmentIndex = function(locator)
    if type(locator) ~= "string" then return nil end
    local d = locator:match("DocFragment%[(%d+)%]")
    return d and tonumber(d)
end

--- xpointer 里 `DocFragment/body` 之后的元素路径（忽略 `text()` 与文本偏移）；取不到返回 nil。
---@param locator string|nil
---@return string|nil
local function locatorElementPath(locator)
    if type(locator) ~= "string" then return nil end
    local rest = locator:match("DocFragment%[%d+%]/body%[%d+%](.*)$")
        or locator:match("DocFragment%[%d+%]/body(.*)$")
        or locator:match("DocFragment/body(.*)$")
    if not rest or rest == "" then return nil end
    local parts = {}
    for seg in rest:gmatch("([^/]+)") do
        if not seg:match("^text%(") then
            local name, index = seg:match("^([%w:_%-]+)%[(%d+)%]$")
            if not name then name = seg:match("^([%w:_%-]+)") end
            if name then parts[#parts + 1] = name .. "[" .. (index or "1") .. "]" end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

--- 元素路径 a 是否在 b 之后（逐段比较：同名同级按下标数值；前缀相同则更长者更靠后）。
---@param a string|nil
---@param b string|nil
---@return boolean
local function elementPathAfter(a, b)
    if not a or not b then return false end
    local sa, sb = {}, {}
    for seg in a:gmatch("[^/]+") do sa[#sa + 1] = seg end
    for seg in b:gmatch("[^/]+") do sb[#sb + 1] = seg end
    local n = math.min(#sa, #sb)
    for i = 1, n do
        if sa[i] ~= sb[i] then
            local na, ia = sa[i]:match("^([%w:_%-]+)%[(%d+)%]$")
            local nb, ib = sb[i]:match("^([%w:_%-]+)%[(%d+)%]$")
            if na and na == nb and ia and ib then
                return tonumber(ia) > tonumber(ib)
            end
            return false
        end
    end
    return #sa > #sb
end

--- 页级源位置比较（**只按 spine + spine 内元素路径**，Kavita 的百分比按 spine 算、进入 spine 就跳变，
--- 不能作依据）。返回 1=远端更靠后，-1=本地更靠后，0=同位，nil=无法判定（缺 spine）。
---@param local_pos ProgressPosition|nil
---@param remote_pos ProgressPosition|nil
---@return integer|nil
spineCmp = function(local_pos, remote_pos)
    local ls = docFragmentIndex(local_pos and local_pos.locator)
    local rs = docFragmentIndex(remote_pos and remote_pos.locator)
    if not ls or not rs then return nil end
    if rs ~= ls then return rs > ls and 1 or -1 end
    local le = locatorElementPath(local_pos.locator)
    local re = locatorElementPath(remote_pos.locator)
    if elementPathAfter(re, le) then return 1 end
    if elementPathAfter(le, re) then return -1 end
    return 0
end

--- 开书对比用的本地进度：位置（locator）以阅读器实时值为准，章信息（chapter_idx/fraction）
--- 取 pending_progress，同章时章内比例优先于章首快照。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
local function localProgressForPull(id, snapshot)
    local live = Progress.position(snapshot)
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row then
        return live
    end
    local pos = rowPosition(row)
    -- 本机实际读到哪，以阅读器（sidecar 恢复）的实时 locator 为准，而不是 pending 行：
    -- 关书推送在「远端更靠后」时会静默把行改写成远端位置（为了书架即时反映），但阅读器
    -- 并未跳转；若这里仍以行的 locator 为准，开书时会把「本机落后」误判成同位置而永不收敛，
    -- 也就没有同步、没有冲突提示。行只在实时位置缺失时兜底。
    if live.locator ~= nil then
        pos.locator = live.locator
    end
    if pos.chapter_idx and live.chapter_idx
        and tonumber(pos.chapter_idx) == tonumber(live.chapter_idx) then
        if pos.chapter_fraction == nil and live.chapter_fraction ~= nil then
            pos.chapter_fraction = live.chapter_fraction
        end
    end
    return pos
end

--- 由全书比例推算第 idx 章的章内比例；比例落不到该章时返回 nil。
---@param fraction number
---@param count integer 目录章数（>0）
---@param idx integer
---@return number|nil
local function withinFromFraction(fraction, count, idx)
    local p = fraction * count
    if math.floor(p) + 1 == idx then
        return p - (idx - 1)
    end
end

--- 冲突弹窗用的可读进度标签（按章书优先章序号，整书优先页码，最后才用全书比例）。
---@param pos ProgressPosition|nil
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@param force_percent boolean|nil 两侧页数单位不同（Kavita spine vs 内容页）时强制用百分比
---@return string
local function conflictLabel(pos, id, snapshot, force_percent)
    pos = pos or {}
    local toc = chapterToc(id, snapshot)
    if toc then
        local count = #toc
        local idx = tonumber(pos.chapter_idx)
        if not idx and count > 0 and pos.fraction then
            idx = math.floor(pos.fraction * count) + 1
        end
        if idx then
            local title = pos.chapter_title
            if (type(title) ~= "string" or title == "") and toc[idx] then
                title = toc[idx].title or toc[idx].name
            end
            if type(title) == "string" then
                local trimmed = Text.trim(title)
                local clipped = Text.truncateUtf8(trimmed, 48)
                title = clipped ~= trimmed and clipped .. "…" or clipped
            else
                title = ""
            end
            local within = pos.chapter_fraction
            if within == nil and count > 0 and pos.fraction then
                within = withinFromFraction(pos.fraction, count, idx)
            end
            local within_pct = within and math.floor(within * 100 + 0.5) or nil
            if title ~= "" and within_pct and within_pct > 0 then
                return T(_("第 %1 章 · %2 · 章内 %3%"), idx, title, within_pct)
            end
            if title ~= "" then
                return T(_("第 %1 章 · %2"), idx, title)
            end
            if within_pct and within_pct > 0 then
                return T(_("第 %1 章 · 章内 %2%"), idx, within_pct)
            end
            return T(_("第 %1 章"), idx)
        end
    end
    if not force_percent then
        local page = tonumber(pos.page)
        local total = tonumber(pos.total_pages)
        if page and total and total > 0 then
            return T(_("第 %1 / %2 页"), math.floor(page), math.floor(total))
        end
    end
    return T(_("%1%"), string.format("%.1f", (tonumber(pos.fraction) or 0) * 100))
end

--- Kavita 页级（page = spine / HTML 文件，不是内容页）的冲突标签：两侧都用
--- `DocFragment[D]` 序号表达，单位一致。`total` 用远端 spine 总数。
---@param pos ProgressPosition|nil
---@param total number|nil spine 总数
---@return string
local function spineConflictLabel(pos, total)
    local d = docFragmentIndex(pos and pos.locator)
    if not d then
        return T(_("%1%"), string.format("%.1f", (tonumber(pos and pos.fraction) or 0) * 100))
    end
    local n = tonumber(total)
    if n and n > 0 then
        return T(_("第 %1 / %2 页"), d, n)
    end
    return T(_("第 %1 页"), d)
end

--- 冲突两侧的展示标签：两侧总页数一致才用页码（同单位）；否则按 spine 对齐
--- （Kavita 的页是 HTML 文件级，本地 total_pages 是内容页，直接并列会误导）。
---@param local_pos ProgressPosition|nil
---@param remote_pos ProgressPosition|nil
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@return string local_desc
---@return string remote_desc
local function conflictLabels(local_pos, remote_pos, id, snapshot)
    local lt = tonumber(local_pos and local_pos.total_pages)
    local rt = tonumber(remote_pos and remote_pos.total_pages)
    if lt and rt and lt > 0 and rt > 0 and lt == rt then
        return conflictLabel(local_pos, id, snapshot), conflictLabel(remote_pos, id, snapshot)
    end
    -- 页数单位不同：若能取到 spine 序号（DocFragment），两侧都用它表达，单位一致。
    if docFragmentIndex(local_pos and local_pos.locator) or docFragmentIndex(remote_pos and remote_pos.locator) then
        return spineConflictLabel(local_pos, rt), spineConflictLabel(remote_pos, rt)
    end
    return conflictLabel(local_pos, id, snapshot, true), conflictLabel(remote_pos, id, snapshot, true)
end

--- 把选定的进度应用到当前文档（按章书跳章，整本书跳比例）。
--- 冲突弹窗两个方向都用它：选云端跳云端位置，选本地跳本地那份记录。
--- 调用前提：已确认 pos 与当前位置不一致且文档身份未变。
--- 只有活动的按章会话才允许切章；冷打开的章节文件按单文档处理。
---@param ui table
---@param id BookIdentity
---@param pos ProgressPosition
---@param pct number clamp 后的全书比例
---@param show_msg boolean|nil
local function applyChosenPos(ui, id, pos, pct, show_msg)
    local toc = chapterToc(id)
    if toc then
        local count = #toc
        local target_idx = tonumber(pos.chapter_idx)
        local within = pos.chapter_fraction
        if not target_idx then
            local p = pct * count
            target_idx = math.max(1, math.min(count, math.floor(p) + 1))
            if within == nil then
                within = p - (target_idx - 1)
            end
        elseif within == nil then
            within = withinFromFraction(pct, count, target_idx) or 0
        end
        if target_idx ~= id.chapter_idx then
            if not require("ui.reader.session").gotoChapter(target_idx, { within = within }) then
                require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                    text = T(_("跳转到 %1 失败"), conflictLabel(pos, id)),
                    timeout = 3,
                })
                return
            end
        else
            -- 已在目标章内：远端 locator 是这一章的坐标，可以直接用。
            applyPosition(ui, pos, within)
        end
    else
        applyPosition(ui, pos, pct)
    end
    if show_msg then
        local InfoMessage = require("ui/widget/infomessage")
        require("ui/uimanager"):show(InfoMessage:new{
            text = T(_("已跳转到 %1"), conflictLabel(pos, id)),
            timeout = 2,
        })
    end
end

--- 按章模式：从远端进度推算章内比例。
---@param pos ProgressPosition
---@param chapter_idx integer|nil
---@param toc_count integer
---@return number
local function remoteWithin(pos, chapter_idx, toc_count)
    local within = pos.chapter_fraction
    if within ~= nil then
        return within
    end
    if toc_count <= 0 then
        return 0
    end
    return withinFromFraction(pos.fraction, toc_count, pos.chapter_idx or chapter_idx) or 0
end

--- 当前阅读位置与 freshly pulled 远端进度是否冲突。
---@param local_pos ProgressPosition|nil
---@param remote_pos ProgressPosition
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@param page_level boolean|nil 远端是页级/spine 级（Kavita），比例不参与内容比对
---@return boolean
progressDiffers = function(local_pos, remote_pos, id, snapshot, page_level)
    -- 精确坐标一致就是同一个位置，不必再拿会漂移的比例去比。
    local here = local_pos and local_pos.locator
    if here and here == remote_pos.locator then
        return false
    end
    local toc = chapterToc(id, snapshot)
    if toc then
        local count = #toc
        local local_idx = local_pos and tonumber(local_pos.chapter_idx)
        local remote_idx = tonumber(remote_pos.chapter_idx)
            or math.floor(remote_pos.fraction * count) + 1
        if local_idx then
            if local_idx ~= remote_idx then
                return true
            end
            local local_within = local_pos.chapter_fraction or 0
            return math.abs(local_within - remoteWithin(remote_pos, remote_idx, count)) >= 0.01
        end
    end
    -- 页级源（Kavita）：比例按 spine 算，进入 spine 就跳变，绝不能拿比例比。
    -- 只要两端都能取到 spine，就按 spine 序号判等；同 spine 视为同一位置，不判冲突。
    if page_level then
        local local_spine = docFragmentIndex(here)
        local remote_spine = docFragmentIndex(remote_pos.locator)
        if local_spine and remote_spine then
            return local_spine ~= remote_spine
        end
        -- 取不到 spine（无定位/单文档）才退回比例，用「一页」容差。
        local local_frac = local_pos and local_pos.fraction or 0
        local tol = 0.01
        local total = tonumber(remote_pos.total_pages)
        if total and total > 0 then tol = math.max(tol, 1 / total) end
        return math.abs(local_frac - remote_pos.fraction) >= tol
    end
    local local_frac = local_pos and local_pos.fraction or 0
    return math.abs(local_frac - remote_pos.fraction) >= 0.01
end

--- 本地与云端进度不一致：询问用户用哪个（本次阅读会话只问一次）。
--- 选云端 → 跳转；选本地 → 把本地推上去收敛，避免下次再问。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@param local_pos ProgressPosition
---@param remote_pos ProgressPosition
local function askProgressConflict(id, snapshot, local_pos, remote_pos)
    local key = id.source_id .. "\31" .. id.stable_id
    if Progress.asked_conflicts[key] then return end
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local local_desc, remote_desc = conflictLabels(local_pos, remote_pos, id, snapshot)
    local local_btn = T(_("本地：%1"), local_desc)
    local remote_btn = T(_("云端：%1"), remote_desc)
    UIManager:show(ConfirmBox:new{
        text = T(_("本地与云端进度不一致（%1 / %2），跳转到哪个？"), local_desc, remote_desc),
        ok_text = remote_btn,
        cancel_text = local_btn,
        ok_callback = function()
            -- 置位挪进回调：点空白关闭弹窗时两个回调都不跑，
            -- 在 show 之前置位会让本次会话再也不问，脏本地进度既不推也不采纳。
            Progress.asked_conflicts[key] = true
            local Session = require("ui.reader.session")
            local current = Session.current()
            if not current or not isSameBook(id) then
                return
            end
            local remote = rowPosition(remote_pos)
            remote.updated_at = os.time()
            if not ProgressDB.adoptRemote(id.source_id, id.stable_id, remote) then
                logger.warn("book.progress adopt remote failed", id.stable_id)
                return
            end
            local live = Session.current()
            if live and isSameBook(id) then
                applyChosenPos(live.ui, live.identity, remote_pos, remote_pos.fraction, true)
            end
        end,
        cancel_callback = function()
            Progress.asked_conflicts[key] = true
            local Session = require("ui.reader.session")
            if not Session.current() or not isSameBook(id) then
                return
            end
            -- 落回弹窗上展示的那份本地进度，不能重新采样实时位置：冷打开的落点
            -- 可能比本地记录更靠前，那会把「保留本地」变成覆盖本地。
            local adopt = {}
            for k, v in pairs(local_pos) do adopt[k] = v end
            adopt.updated_at = nextRevision()
            if not ProgressDB.upsert(id.source_id, id.stable_id, adopt) then
                logger.warn("book.progress adopt local failed", id.stable_id)
                return
            end
            local live = Session.current()
            if live and isSameBook(id) then
                applyChosenPos(live.ui, live.identity, adopt, adopt.fraction, false)
            end
            if id.source and id.source.syncProgressAsync then
                -- 用户明确保留本地：本地位置权威，force 跳过「远端更靠后就不推」的比对，
                -- 直接把本地推上去收敛，否则下次开书还会再弹同一次。
                id.source:syncProgressAsync({ identity = id, dirty_only = true, force = true },
                    function() end)
            end
        end,
    })
end

--- 重连/后台同步发现本地脏进度与云端不一致：让用户选保留哪份并据此收敛。
--- 选云端 → 采纳云端（覆盖本地，置干净）；选本地 → 回推本地（覆盖云端）。
--- 点空白关闭则两个回调都不跑，脏行保留，下次重连再问。
---@param source BookSource
---@param id BookIdentity
---@param local_pos ProgressPosition
---@param remote_pos ProgressPosition
---@param on_choice fun(choice: "local"|"cloud")
function Progress.askReconnectConflict(source, id, local_pos, remote_pos, on_choice)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local local_desc, remote_desc = conflictLabels(local_pos, remote_pos, id)
    UIManager:show(ConfirmBox:new{
        text = T(_("本地与云端进度不一致（%1 / %2），保留哪个？"), local_desc, remote_desc),
        ok_text = T(_("云端：%1"), remote_desc),
        cancel_text = T(_("本地：%1"), local_desc),
        ok_callback = function() on_choice("cloud") end,
        cancel_callback = function() on_choice("local") end,
    })
end

--- 远端进度是否代表「确实读过」：全 0 / 首页/首章视为无进度，不触发首次打开跳转。
--- 部分源（微信）对没读过的书也会回一个零值进度，不能据此改写本地并弹「已跳转」。
---@param pos ProgressPosition|nil
---@return boolean
local function hasRemoteProgress(pos)
    if not pos then return false end
    if (tonumber(pos.fraction) or 0) > 0 then return true end
    if (tonumber(pos.chapter_idx) or 1) > 1 then return true end
    if (tonumber(pos.chapter_fraction) or 0) > 0 then return true end
    if (tonumber(pos.page) or 1) > 1 then return true end
    return false
end

--- 采纳远端进度落库（干净状态，带当前时间戳）；成功返回 true。
---@param id BookIdentity
---@param remote_pos ProgressPosition
---@return boolean
local function adoptRemoteNow(id, remote_pos)
    local remote = rowPosition(remote_pos)
    remote.updated_at = os.time()
    return ProgressDB.adoptRemote(id.source_id, id.stable_id, remote)
end

--- 首次打开（本地无进度行）：云端有进度就直接采纳并跳转，不走冲突询问。
--- 本地既无进度可冲突，也不必保留；按云端位置落库让读完状态与书架进度一致。
---@param id BookIdentity
---@param remote_pos ProgressPosition
local function adoptFirstOpen(id, remote_pos)
    local Session = require("ui.reader.session")
    local live = Session.current()
    if not live or not isSameBook(id) then return end
    if not adoptRemoteNow(id, remote_pos) then
        logger.warn("book.progress first-open adopt remote failed", id.stable_id)
        return
    end
    logger.dbg("book.progress reader pull first-open adopt", id.source_id, id.stable_id)
    applyChosenPos(live.ui, live.identity, remote_pos, remote_pos.fraction, true)
end

--- 拉远端进度并与当前阅读位置收敛：冲突弹窗、同 spine 远端更靠后采纳、无冲突落库。
--- syncProgressAsync 只推不拉；本函数是进度 pull 的唯一入口（开书 + 手动「拉取进度」）。
---@param snapshot ReaderSessionSnapshot
---@param opts { manual?: boolean }|nil manual=true 时：无视会话去重、离线/无远端/已一致都给提示
function Progress.pull(snapshot, opts)
    opts = opts or {}
    local manual = opts.manual == true
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local function tell(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
    end
    if not source or type(source.getProgressAsync) ~= "function" then
        if manual then tell(_("此数据源不支持云端进度")) end
        return
    end
    if manual then
        if not require("ui/network/manager"):isOnline() then
            tell(_("网络不可用，请先连接 Wi-Fi"))
            return
        end
        -- 手动触发：清掉本次会话的「已问过」记忆，保证一定会重新弹。
        Progress.asked_conflicts[id.source_id .. "\31" .. id.stable_id] = nil
    end
    logger.dbg("book.progress reader pull start", id.source_id, id.stable_id,
        id.chapter_idx or "book")
    source:getProgressAsync(id, function(remote_pos, err, meta)
        if not isSameBook(id) then
            logger.dbg("book.progress pull skip: document changed")
            return
        end
        if type(meta) == "table" and meta.empty then
            logger.dbg("book.progress reader pull empty", id.source_id, id.stable_id)
            if manual then tell(_("云端暂无这本书的进度")) end
            return
        end
        if not remote_pos then
            -- 离线开缓存书是正常路径；拉不到云端进度只记日志，不能打断阅读。
            logger.warn("book.progress reader pull failed", id.source_id, id.stable_id, err)
            if manual then tell(_("无法获取云端进度")) end
            return
        end
        local page_level = type(meta) == "table" and meta.page_level == true
        local local_position = localProgressForPull(id, snapshot)
        local row = ProgressDB.get(id.source_id, id.stable_id)
        if not row then
            -- 首次打开/无本地进度：没有可冲突的进度，云端确有进度就直接采纳并跳转，不弹窗。
            if hasRemoteProgress(remote_pos) then
                adoptFirstOpen(id, remote_pos)
            else
                logger.dbg("book.progress reader pull first-open no remote progress",
                    id.source_id, id.stable_id)
                if manual then tell(_("云端暂无这本书的进度")) end
            end
            return
        end
        -- 页级源只比 spine 序号 + spine 内元素路径（**绝不用百分比**）。
        -- 跨 spine 分歧（多设备停在不同章节）：弹窗让用户选，绝不静默把本机拉走；
        -- 同 spine 才做细粒度收敛：远端元素更靠后/已读完 → 采纳远端；否则保留本地（脏则推）。
        if page_level then
            local local_spine = docFragmentIndex(local_position and local_position.locator)
            local remote_spine = docFragmentIndex(remote_pos.locator)
            if local_spine and remote_spine then
                if local_spine ~= remote_spine then
                    logger.dbg("book.progress reader pull spine conflict", id.source_id, id.stable_id)
                    askProgressConflict(id, snapshot, local_position, remote_pos)
                    return
                end
                local cmp = spineCmp(local_position, remote_pos)
                if cmp == 1 or (tonumber(remote_pos.fraction) or 0) >= 1 then
                    logger.dbg("book.progress reader pull remote-ahead adopt", id.source_id, id.stable_id)
                    if adoptRemoteNow(id, remote_pos) then
                        local Session = require("ui.reader.session")
                        local live = Session.current()
                        if live and isSameBook(id) then
                            applyChosenPos(live.ui, live.identity, remote_pos, remote_pos.fraction, manual)
                        end
                    else
                        logger.warn("book.progress save remote failed", id.stable_id)
                    end
                    return
                end
                if row.sync_status == 0 and source.syncProgressAsync then
                    source:syncProgressAsync({ identity = id, dirty_only = true }, function() end)
                end
                logger.dbg("book.progress reader pull keep-local", id.source_id, id.stable_id)
                if manual then tell(_("进度已是最新")) end
                return
            end
            -- 取不到 spine → 退回通用判定（可能弹窗）
        end
        if progressDiffers(local_position, remote_pos, id, snapshot, page_level) then
            logger.dbg("book.progress reader pull conflict", id.source_id, id.stable_id)
            askProgressConflict(id, snapshot, local_position, remote_pos)
            return
        end
        if row.sync_status == 0 then
            -- 本地脏版本与云端基本一致时只推不拉；上面已经拿到了最新远端，
            -- 再跑完整同步只会产生第二次相同的 getProgress。
            if source.syncProgressAsync then
                source:syncProgressAsync({ identity = id, dirty_only = true }, function() end)
            end
        elseif not ProgressDB.upsertRemote(id.source_id, id.stable_id, remote_pos) then
            logger.warn("book.progress save remote failed", id.stable_id)
            return
        end
        logger.dbg("book.progress reader pull done", id.source_id, id.stable_id, "matched")
        if manual then tell(_("进度已是最新")) end
    end)
end

--- 手动把当前阅读进度推到云端（覆盖远端，不回拉比对）。阅读页「Kavita：同步进度」用。
--- 阅读中 pending 行可能还停在开书位置，所以先 `Progress.save` 落盘当前阅读位置，再 force 推。
---@param snapshot ReaderSessionSnapshot
function Progress.push(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local function tell(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
    end
    local source = id.source
    if not source or type(source.syncProgressAsync) ~= "function" then
        tell(_("此数据源不支持云端进度"))
        return
    end
    if not require("ui/network/manager"):isOnline() then
        tell(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    Progress.save(snapshot, function(ok)
        if not ok then
            logger.warn("book.progress manual push save failed", id.stable_id)
            tell(_("进度保存失败"))
            return
        end
        logger.dbg("book.progress manual push start", id.source_id, id.stable_id)
        source:syncProgressAsync({ identity = id, dirty_only = true, force = true }, function(result, err)
            if result and not result.push_error then
                tell(_("已同步到云端"))
            else
                logger.warn("book.progress manual push failed", id.source_id, id.stable_id,
                    err or (result and result.push_error))
                tell(_("同步失败"))
            end
        end)
    end)
end

--- 清空「已问过进度冲突」的记忆，下次开书会重新弹 ConfirmBox。
--- 由 Session.onCloseDocument 在真正关书（非切章）时调用。
function Progress.clearConflicts()
    Progress.asked_conflicts = {}
end

return Progress
