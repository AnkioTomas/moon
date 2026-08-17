--[[--
章节 materialize：TOC、拉正文、写 HTML、预取、inflight 去重。

@module koplugin.book.chapters.materialize
--]]

local UIManager = require("ui/uimanager")
local Store = require("book.store")
local ProgressPosition = require("types.book_progress")
local Html = require("chapters.html")
local Session = require("chapters.session")
local _ = require("gettext")

local Materialize = {
    _ensure_inflight = {},
    --- 目录缓存 TTL（秒）：6 小时
    TOC_TTL = 6 * 60 * 60,
}

--- 清掉所有 in-flight waiter（关书/换书后迟到回调不得落盘 UI）。
function Materialize.cancelInflight()
    Materialize._ensure_inflight = {}
end

--- 按 idx 在目录中找章节。
---@param toc BookChapter[]|nil
---@param idx number
---@return BookChapter|nil
local function findChapter(toc, idx)
    if type(toc) ~= "table" then
        return nil
    end
    for _, c in ipairs(toc) do
        if tonumber(c.idx) == idx then
            return c
        end
    end
    return toc[idx]
end

--- 异步拉目录；回调 cb(ok, chapters, err, from_cache)。
--- online 源目录落 toc 表缓存（6 小时）：开书不再每次重拉；命中时 from_cache=true。
--- article(rss) 不缓存：目录会头插新文章，feed 自身已有 15 分钟内存缓存 +
--- 指纹对账（rss.reconcileChapterCache），每次现拉廉价且正确。
---@param source BookSource
---@param ref BookRef
---@param cb fun(ok: boolean, chapters: BookChapter[]|nil, err: any, from_cache: boolean|nil)
---@param no_cache boolean|nil 跳过缓存直拉（缓存偏旧重拉用）
function Materialize.loadTocAsync(source, ref, cb, no_cache)
    if type(cb) ~= "function" then
        return
    end
    if not source or not source.getTocAsync then
        UIManager:nextTick(function()
            cb(false, nil, _("数据源不支持目录"))
        end)
        return
    end
    local use_cache = not no_cache and source.type == "online"
        and type(ref) == "table" and ref.source_id and ref.stable_id
    if use_cache then
        local payload = require("utils.db.toc").get(ref.source_id, ref.stable_id, Materialize.TOC_TTL)
        if payload then
            local ok, cached = pcall(function()
                return require("json").decode(payload)
            end)
            if ok and type(cached) == "table" and #cached > 0 then
                UIManager:nextTick(function()
                    cb(true, cached, nil, true)
                end)
                return
            end
        end
    end
    source:getTocAsync(ref, function(chapters, err)
        if not chapters then
            cb(false, nil, err or _("无法获取目录"))
            return
        end
        if type(chapters) ~= "table" or #chapters == 0 then
            cb(false, nil, _("目录为空"))
            return
        end
        local normalized = {}
        for i, ch in ipairs(chapters) do
            normalized[#normalized + 1] = {
                idx = tonumber(ch.idx) or i,
                source_idx = ch.source_idx,
                uid = ch.uid,
                title = (ch.title and ch.title ~= "") and ch.title or tostring(i),
            }
        end
        if use_cache then
            local ok, payload = pcall(function()
                return require("json").encode(normalized)
            end)
            if ok and payload then
                local source_id, stable_id = ref.source_id, ref.stable_id
                require("utils.db.queue").run(function()
                    require("utils.db.toc").upsert(source_id, stable_id, payload)
                end)
            end
        end
        cb(true, normalized)
    end)
end

--- 删除旧版单章 .epub（格式已改为 .html）。
---@param path string html 目标路径
local function purgeLegacyEpub(path)
    if type(path) ~= "string" then
        return
    end
    local legacy = path:gsub("%.html$", ".epub")
    if legacy ~= path then
        pcall(os.remove, legacy)
        pcall(os.remove, legacy .. ".part")
    end
end

--- 异步确保章节 HTML；回调 cb(ok, path, err)。
---@param source BookSource
---@param ref BookRef
---@param idx number|string
---@param toc BookChapter[]|nil
---@param cb fun(ok: boolean, path: string|nil, err: any)
function Materialize.ensureAsync(source, ref, idx, toc, cb)
    if type(cb) ~= "function" then
        return
    end
    idx = tonumber(idx) or 1
    local path = Store.chapterPath(ref.stable_id, idx, ref.source_id)
    purgeLegacyEpub(path)
    if Html.isValid(path) then
        UIManager:nextTick(function()
            cb(true, path)
        end)
        return
    end
    if not source or not source.fetchChapterContentAsync then
        UIManager:nextTick(function()
            cb(false, nil, _("数据源不支持按章下载"))
        end)
        return
    end

    local key = ref.source_id .. ":" .. ref.stable_id .. ":" .. idx
    local inflight = Materialize._ensure_inflight[key]
    if inflight then
        table.insert(inflight.waiters, cb)
        return
    end

    Materialize._ensure_inflight[key] = { waiters = { cb } }

    toc = toc or Session.toc()
    local ch = findChapter(toc, idx) or { idx = idx, title = tostring(idx) }

    source:fetchChapterContentAsync(ref, ch, function(payload, err)
        local job = Materialize._ensure_inflight[key]
        -- 已被 clear 清掉 inflight：迟到结果直接丢弃
        if not job then
            return
        end
        Materialize._ensure_inflight[key] = nil
        local waiters = job.waiters or { cb }

        local function fail(msg)
            for _, w in ipairs(waiters) do
                pcall(w, false, nil, msg)
            end
        end

        if not payload then
            fail(err or _("章节下载失败"))
            return
        end
        -- 换书/关书后 generation 变了：仍可落盘缓存，但 waiter 若会话已死由上层吞 UI
        if type(payload) == "table" and (not payload.title or payload.title == "") then
            payload.title = ch.title or tostring(idx)
        elseif type(payload) == "string" then
            payload = { title = ch.title or tostring(idx), html = payload }
        end

        local ok_write, write_err = Html.write(path, payload)
        if not ok_write then
            pcall(os.remove, path .. ".part")
            fail(write_err or _("写入章节失败"))
            return
        end
        for _, w in ipairs(waiters) do
            pcall(w, true, path)
        end
    end)
end

--- 预取当前章前后（前 1 后 3）。
---@param idx number|string|nil
function Materialize.prefetchAround(idx)
    local s = Session.get()
    if not s or not s.ref then
        return
    end
    idx = tonumber(idx) or s.idx or 1
    local count = Session.chapterCount() or 0
    local targets = {}
    -- 与后 3 一样以目录为界：count=0（无目录）时不预取可能不存在的章
    if count > 0 and idx - 1 >= 1 then
        targets[#targets + 1] = idx - 1
    end
    for d = 1, 3 do
        if idx + d <= count then
            targets[#targets + 1] = idx + d
        end
    end
    local source = s.source
    local ref = s.ref
    local toc = s.toc
    for _, tidx in ipairs(targets) do
        local path = Store.chapterPath(ref.stable_id, tidx, ref.source_id)
        if not Html.isValid(path) then
            Materialize.ensureAsync(source, ref, tidx, toc, function() end)
        end
    end
end

--- 本地已知的阅读位置：pending_progress（未同步的本地进度）→ opens.chapter_idx（上次读到的章）。
---@param ref BookRef
---@return ProgressPosition|nil
local function localPosition(ref)
    if type(ref) ~= "table" or not ref.source_id or not ref.stable_id then
        return nil
    end
    local p = require("utils.db.progress").get(ref.source_id, ref.stable_id)
    if p and (tonumber(p.chapter_idx) or (tonumber(p.fraction) or 0) > 0) then
        return {
            fraction = p.fraction,
            chapter_idx = p.chapter_idx,
            chapter_fraction = p.chapter_fraction,
        }
    end
    local o = require("utils.db.open").get(ref.source_id, ref.stable_id)
    if o and tonumber(o.chapter_idx) then
        return { chapter_idx = tonumber(o.chapter_idx) }
    end
    return nil
end

--- 异步准备按章打开；回调 cb(ok, prep, err)。
--- 起始章本地优先（pending/opens），都没有才用云端进度；
--- 本地与云端不一致由 ReaderReady 的 Progress.pull 弹窗询问。
---@param source BookSource
---@param book Book
---@param ref BookRef
---@param cb fun(ok: boolean, prep: table|nil, err: any)
function Materialize.prepareOpenAsync(source, book, ref, cb)
    if type(cb) ~= "function" then
        return
    end
    local function prepareWithBook(book2)
        Materialize.loadTocAsync(source, ref, function(tok, toc, terr, from_cache)
            if not tok or not toc or #toc == 0 then
                cb(false, nil, terr or _("无法获取目录"))
                return
            end
            local function finish(pos, cur_toc, cur_cached, reloaded)
                -- 缓存目录偏旧（连载加章）：进度指向的章超出目录，弃缓存重拉一次
                local ci = pos and tonumber(pos.chapter_idx)
                if cur_cached and not reloaded and ci and ci > #cur_toc then
                    Materialize.loadTocAsync(source, ref, function(tok2, toc2)
                        if tok2 and toc2 and #toc2 > 0 then
                            finish(pos, toc2, nil, true)
                            return
                        end
                        finish(pos, cur_toc, nil, true) -- 重拉失败仍用缓存目录（clamp 兜底）
                    end, true)
                    return
                end
                local start_idx = 1
                if pos then
                    if tonumber(pos.chapter_idx) then
                        start_idx = tonumber(pos.chapter_idx)
                    else
                        local pct = ProgressPosition.clampFraction(pos.fraction)
                        if pct > 0 then
                            start_idx = math.floor(pct * #cur_toc) + 1
                        end
                    end
                end
                -- chapter_idx 与 fraction 两条路径统一 clamp 到目录范围
                start_idx = math.max(1, math.min(#cur_toc, start_idx))
                cb(true, {
                    book = book2,
                    toc = cur_toc,
                    start_idx = start_idx,
                })
            end
            local lpos = localPosition(ref)
            if lpos then
                finish(lpos, toc, from_cache)
            elseif source and source.getProgressAsync then
                source:getProgressAsync(ref, function(pos)
                    finish(pos, toc, from_cache)
                end)
            else
                finish(nil, toc, from_cache)
            end
        end)
    end
    if source and source.getDetailAsync then
        source:getDetailAsync(ref, function(detail)
            if detail then
                Store.remember(detail)
            end
            prepareWithBook(detail or book)
        end)
    else
        prepareWithBook(book)
    end
end

return Materialize
