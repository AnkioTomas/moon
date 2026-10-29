--[[--
连续章节阅读编排：跨 switchDocument 的章节会话。

@module koplugin.book.reader.session.chapter
--]]

local Snapshot = require("reader.session.snapshot")
local _ = require("gettext")

---@class ReaderChapterSession
---@field identity BookIdentity|nil 书籍身份与属主源
---@field toc BookChapter[] 从 books.toc 恢复的目录快照；开书 / 临近章末后台静默拉新，失败仍用这份
---@field open_refresh boolean|nil 新开这本书：afterBootstrap 应尝试拉目录（节流挡住则保留到下次）
---@field request { cancel: fun() }|nil 在途章节打开任务
---@field target { path: string, within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }|nil 已下载、等待 ReaderReady 的目标
---@field toc_job { cancel: fun() }|nil 目录恢复 / 后台刷新任务
---@field switching boolean|nil 已进入 switchDocument，同步 CloseDocument 应保留本书会话

local Chapter = {}

local PREFETCH_AHEAD = 3
--- 目录剩余不超过这么多章时，切章后后台再拉一次（连载追更）。
Chapter.REFRESH_REMAINING = 5
--- 切章（取章 + switchDocument）超过这么久按 warn 落盘。
Chapter.SLOW_SWITCH_MS = 3000

---@type ReaderChapterSession|nil
local chapter_session
---@type { cancel: fun() }|nil
local prefetch_job
local transition_notice

local function closeTransitionNotice()
    if transition_notice then
        require("ui/uimanager"):close(transition_notice)
        transition_notice = nil
    end
end

local function showTransitionNotice()
    closeTransitionNotice()
    if require("utils.settings").get("reader").chapter_switch_notice == false then return end
    transition_notice = require("ui.themes.widgets.toast"):new{
        text = _("正在切换章节，请稍候…"),
    }
    require("ui/uimanager"):show(transition_notice)
end

--- 取消在途的后续章预取任务。
--- 先清模块状态再 cancel，避免 cancel 回调重入时又看到已废弃的 job。
local function cancelPrefetch()
    local job = prefetch_job
    prefetch_job = nil
    if job and job.cancel then job.cancel() end
end

---@param session ReaderSessionSnapshot|nil
function Chapter.clearActiveChapter(session)
    local chapter = chapter_session
    chapter_session = nil
    cancelPrefetch()
    if session then session.chapter = nil end
    if chapter and chapter.request and chapter.request.cancel then chapter.request.cancel() end
    if chapter and chapter.toc_job and chapter.toc_job.cancel then chapter.toc_job.cancel() end
    closeTransitionNotice()
end

---@param session ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
function Chapter.toc(session)
    local chapter = session and session.chapter
    return chapter and chapter.toc or nil
end

---@param snapshot ReaderSessionSnapshot|nil
---@return string|nil
function Chapter.chapterTitle(snapshot)
    local toc = snapshot and snapshot.chapter and snapshot.chapter.toc
    local entry = toc and toc[snapshot.identity.chapter_idx]
    local title = entry and require("utils.text").trim(entry.title or "")
    return title ~= "" and title or nil
end

---@param chapter ReaderChapterSession
---@param ui table
local function applyChapterTarget(chapter, ui)
    local target = chapter.target
    chapter.target = nil
    chapter.switching = false
    if not target then return end
    if target.within == nil and target.direction == nil and target.xpointer == nil then return end
    local within, direction = target.within, target.direction

    require("ui/uimanager"):nextTick(require("ui.guard").wrap("chapter jump", function()
        if chapter_session ~= chapter or ui.document.file ~= target.path then return end
        if target.xpointer then
            ui:handleEvent(require("ui/event"):new("GotoXPointer", target.xpointer, target.xpointer))
            return
        end
        if within ~= nil then
            require("reader.session.progress").gotoFraction(ui, within)
            return
        end
        local page = 1
        if direction == "prev" then
            page = ui.document:getPageCount()
            if page <= 1 then return end
        end
        if ui.link then
            ui.link:addCurrentLocationToStack()
        end
        ui:handleEvent(require("ui/event"):new("GotoPage", page))
    end))
end

---@param view table|nil
---@param position fun(view: table): number
---@param atStart fun(before: number, after: number): boolean
local function wrapBoundary(view, position, atStart)
    if not view then return end
    local original = view.onGotoViewRel
    if type(original) ~= "function" then return end
    view.onGotoViewRel = function(self, diff)
        if not chapter_session then return original(self, diff) end
        local before = position(self)
        local result = original(self, diff)
        if diff < 0 and atStart(before, position(self)) then
            require("ui.guard").call("chapter boundary", Chapter.onChapterBoundary,
                require("reader.session").current(), -1)
        end
        return result
    end
end

---@param ui table
local function wrapChapterReaderUi(ui)
    if not ui or ui.name ~= "ReaderUI" or ui._book_chapters_wrapped then return end
    ui._book_chapters_wrapped = true
    wrapBoundary(ui.rolling, function(view)
        if view.view and view.view.view_mode == "scroll" then
            return view.current_pos
        end
        return view.current_page
    end, function(before, after)
        return before == after
    end)
    wrapBoundary(ui.paging, function(view)
        return view.getTopPage and view:getTopPage() or view.current_page
    end, function(before, after)
        return before == 1 and after == before
    end)
end

---@param chapter ReaderChapterSession
local function schedulePrefetch(chapter)
    cancelPrefetch()
    if not chapter or chapter.request or chapter.target or chapter.switching then return end
    local identity = chapter.identity
    local source = identity and identity.source
    if not source or not identity.chapter_idx
        or type(chapter.toc) ~= "table" or type(source.prefetchChaptersAsync) ~= "function" then
        return
    end
    prefetch_job = source:prefetchChaptersAsync(identity, chapter.toc, identity.chapter_idx, PREFETCH_AHEAD)
end

---@param plugin table
---@param session ReaderSessionSnapshot
---@return boolean nav_target 切章导航目标已指定，跳过 pending 本地进度
function Chapter.onReaderReady(plugin, session)
    local ui = plugin.ui
    local identity = session.identity
    local previous = chapter_session
    local same_book = previous
        and previous.identity
        and previous.identity.source_id == identity.source_id
        and previous.identity.stable_id == identity.stable_id
    local chapter
    if same_book then
        ---@cast previous ReaderChapterSession
        chapter = previous
        cancelPrefetch()
        if chapter.request and chapter.request.cancel then chapter.request.cancel() end
        chapter.request = nil
        chapter.identity = identity
    else
        Chapter.clearActiveChapter(nil)
        -- 有缓存就先装上：离线时它是唯一真相（目录展示、章末切章都靠它）。
        -- 拉新交给 afterBootstrap 后台静默做，失败不动这份。
        local toc = require("source.toc").read(identity.source_id, identity.stable_id)
        chapter = {
            identity = identity,
            toc = toc,
            open_refresh = true,
            switching = false,
        }
        chapter_session = chapter
    end

    local target = chapter.target
    local nav_target = target ~= nil and target.path == ui.document.file
    if target and not nav_target then
        chapter.target = nil
        chapter.switching = false
        closeTransitionNotice()
    end
    session.chapter = chapter
    if nav_target then closeTransitionNotice() end
    applyChapterTarget(chapter, ui)
    wrapChapterReaderUi(ui)
    Snapshot.refresh(session)
    if not nav_target then
        require("reader.session.progress").applyLocalPending(session)
        Snapshot.refresh(session)
    end
    return nav_target
end

---@param plugin table
---@param session ReaderSessionSnapshot
function Chapter.afterBootstrap(plugin, session)
    local chapter = session.chapter
    -- 属主源可能已不在（第三方源插件被卸载）：章节照读，只是不发源事件、不预取。
    local source = chapter and session.identity.source
    if not source then return end
    source:onEvent("chapter_changed", {
        identity = session.identity,
        position = require("reader.session.progress").position(session),
    })
    local identity = chapter.identity
    if not identity then return end
    local has_toc = type(chapter.toc) == "table" and #chapter.toc > 0
    local format_ok = type(source.isTocCurrent) ~= "function" or source:isTocCurrent(chapter.toc)
    -- 格式仍认的旧目录先预取；格式过期的等刷新成功再预取，避免按旧 uid 下章。
    if has_toc and format_ok then schedulePrefetch(chapter) end
    local idx = tonumber(identity.chapter_idx)
    local remaining = has_toc and idx and (#chapter.toc - idx) or nil
    local near_end = remaining ~= nil and remaining <= Chapter.REFRESH_REMAINING
    -- 开书 / 缺目录 / 格式过期 / 剩余 ≤5 章：才打网拉新。中间章不刷。
    if not (chapter.open_refresh or not has_toc or not format_ok or near_end) then
        return
    end
    -- 有强制刷新走强制；没有则仅在缺目录时 load（load 命中缓存不会打网）。
    local refresh = source.refreshTocAsync
    if type(refresh) ~= "function" then
        if has_toc then
            chapter.open_refresh = nil
            return
        end
        refresh = source.loadTocAsync
    end
    if type(refresh) ~= "function" then
        chapter.open_refresh = nil
        return
    end
    -- 节流：刚拉过 / 刚试过就跳过；挡住时保留 open_refresh，下次切章再试。
    if not require("source.toc").allowRefresh(identity.source_id, identity.stable_id) then
        return
    end
    chapter.open_refresh = nil
    if chapter.toc_job and chapter.toc_job.cancel then chapter.toc_job.cancel() end
    chapter.toc_job = refresh(source, identity, function(toc)
        chapter.toc_job = nil
        if chapter_session ~= chapter or session.chapter ~= chapter then return end
        if type(toc) ~= "table" or #toc == 0 then
            -- 失败：旧目录不动、不提示；有旧目录就继续预取。
            if has_toc and format_ok then schedulePrefetch(chapter) end
            return
        end
        chapter.toc = toc
        Snapshot.refresh(session)
        require("ui/uimanager"):setDirty(plugin.ui.dialog, "ui")
        schedulePrefetch(chapter)
    end)
end

---@param session ReaderSessionSnapshot|nil
---@return boolean clear_conflicts 是否清除进度冲突记忆
function Chapter.onCloseDocument(session)
    if not (chapter_session and chapter_session.switching) then
        Chapter.clearActiveChapter(session)
        return true
    end
    return false
end

--- 切章失败：收起提示、报错并恢复预取。
---@param chapter ReaderChapterSession
---@param text string
local function failRequest(chapter, text)
    closeTransitionNotice()
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
    schedulePrefetch(chapter)
end

---@param chapter ReaderChapterSession
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }
local function requestChapter(chapter, idx, opts)
    cancelPrefetch()
    showTransitionNotice()
    local identity = chapter.identity
    if not identity then return end
    local source = identity.source
    if not source then return end
    -- 切章 = 取章（网络 / 缓存）+ switchDocument（同步阻塞）；之后 ReaderReady 自己有 reader.ready 一段。
    local span = require("utils.perf").begin("chapter.switch")
    chapter.request = source:openBookAsync(identity, { chapter_idx = idx }, function(path, err)
        chapter.request = nil
        span:lap("fetch")
        if chapter_session ~= chapter then return end
        if not path then
            span:finish(Chapter.SLOW_SWITCH_MS, idx, "failed")
            failRequest(chapter, err or _("章节打开失败"))
            return
        end

        -- 目录跳转不带方向：一律落到章首；只有翻页越界（显式 prev）才回上一章尾部
        local within = opts.within
        local direction = within == nil and (opts.direction or "next") or nil
        chapter.target = {
            path = path,
            within = within,
            direction = direction,
            xpointer = opts.xpointer,
        }

        local ReaderUI = require("apps/reader/readerui")
        local UIManager = require("ui/uimanager")
        -- 先把提示实际刷到屏幕，再让出一个 tick 启动 KOReader 的阻塞式 HTML 打开。
        -- 直接调用 switchDocument 会立刻被 ReaderUI 的 invisible opening message 覆盖，
        -- 用户看不到“正在切换”提示。
        if UIManager.forceRePaint then
            UIManager:forceRePaint()
        end
        UIManager:nextTick(function()
            if chapter_session ~= chapter then return end
            chapter.switching = true
            local ok, switch_err = pcall(function()
                if ReaderUI.instance then
                    ReaderUI.instance:switchDocument(path, true)
                else
                    ReaderUI:showReader(path, nil, true)
                end
            end)
            span:lap("switch"):finish(Chapter.SLOW_SWITCH_MS, idx)
            if not ok and chapter_session == chapter then
                chapter.switching = false
                chapter.target = nil
                failRequest(chapter, tostring(switch_err or _("章节打开失败")))
            end
        end)
    end)
end

---@param session ReaderSessionSnapshot|nil
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }|nil
---@return boolean
function Chapter.gotoChapter(session, idx, opts)
    if not session then return false end
    local chapter = session.chapter
    local current_idx = session.identity.chapter_idx
    if not chapter or type(chapter.toc) ~= "table"
        or chapter.request or chapter.target or chapter.switching
        or idx < 1 or idx > #chapter.toc then
        return false
    end
    if current_idx and idx == current_idx then
        local xpointer = opts and opts.xpointer
        if not xpointer then return false end
        session.ui:handleEvent(require("ui/event"):new("GotoXPointer", xpointer, xpointer))
        return true
    end
    requestChapter(chapter, idx, opts or {})
    return true
end

--- 重新下载当前章：删掉这一章的缓存文件，按同一章号重新打开，其它章不动。
--- 断网时不删（删了就读不了），正在切章 / 取章时忽略。
---@param session ReaderSessionSnapshot|nil
---@return boolean started
function Chapter.reloadChapter(session)
    local chapter = session and session.chapter
    local idx = session and session.identity.chapter_idx
    if not chapter or not idx or chapter.request or chapter.target or chapter.switching then return false end
    if not require("ui/network/manager"):isConnected() then
        require("ui.themes.widgets.toast"):new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return false
    end
    local identity = session.identity
    os.remove(require("utils.paths").chapterPath(identity.stable_id, idx, identity.source_id))
    local entry = chapter.toc and chapter.toc[idx]
    if entry and identity.source.dropChapterCache then identity.source:dropChapterCache(identity, entry) end
    requestChapter(chapter, idx, {})
    return true
end

---@param session ReaderSessionSnapshot|nil
---@param delta integer
---@return boolean
function Chapter.onChapterBoundary(session, delta)
    if not session then return false end
    local chapter = session.chapter
    if not chapter or type(chapter.toc) ~= "table" then
        return false
    end
    if chapter.request or chapter.target or chapter.switching then
        return true
    end
    local current = tonumber(session.identity.chapter_idx)
    if not current then return false end
    local target = current + delta
    if target < 1 or target > #chapter.toc then return false end
    requestChapter(chapter, target, {
        direction = delta < 0 and "prev" or "next",
    })
    return true
end

return Chapter
