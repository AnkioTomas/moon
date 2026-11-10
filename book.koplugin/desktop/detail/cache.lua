--[[-- 章节缓存：范围选择与入队进度，详情页与阅读快捷面板共用。
@module koplugin.book.desktop.detail.cache
--]]

local Toast = require("ui.themes.widgets.toast")
local bookOwnerSource = require("desktop.detail.common").bookOwnerSource
local _ = require("gettext")
local T = require("ffi/util").template

local Cache = {}

---@param book table
---@return string
function Cache.key(book)
    return "cache\0" .. book.source_id .. "\0" .. book.stable_id
end

--- 章节缓存结果提示：成功 / 部分完成 / 失败。
---@param result { ok: boolean, cached: integer, total: integer, failed: integer, err: string|nil, failed_idx: integer[]|nil, reviews?: { ok: boolean, done: integer, err?: string } }
function Cache.notify(result)
    local text
    if result.ok then
        text = _("缓存完成：") .. result.cached .. " / " .. result.total .. _(" 章")
    elseif result.total > 0 then
        text = _("缓存部分完成：") .. result.cached .. " / " .. result.total .. _(" 章")
        if result.failed > 0 then text = text .. "，" .. result.failed .. _(" 章失败") end
        if result.failed_idx and #result.failed_idx > 0 then
            local shown = {}
            for i = 1, math.min(#result.failed_idx, 10) do shown[i] = result.failed_idx[i] end
            text = text .. "\n" .. T(_("失败章节：第 %1 章"), table.concat(shown, "、")
                .. (#result.failed_idx > 10 and "…" or ""))
        end
        if result.err then text = text .. "\n" .. result.err end
    else
        text = result.err or _("缓存失败")
    end
    local reviews = result.reviews
    if reviews then
        text = text .. "\n" .. (reviews.ok and T(_("段评已缓存 %1 章"), reviews.done)
            or T(_("段评缓存到第 %1 章中止：%2"), reviews.done, reviews.err or _("失败")))
    end
    Toast:new{ text = text, timeout = 5 }:show()
end

--- 属主源是否支持章节缓存。
---@param book table
---@param fallback_source table|nil
---@return boolean
function Cache.supported(book, fallback_source)
    local source = bookOwnerSource(book, fallback_source)
    return source ~= nil and source.type == "chapter"
        and type(source.cacheAllChaptersAsync) == "function"
end

--- 选择缓存范围：全本 / 当前进度到结尾 / 当前进度往后 N 章（当前章取本地进度，无进度即第 1 章）。
--- 源支持段评时多一个开关：同时缓存段评（每句只缓存前 10 条评论，请求频繁有封号风险）。
---@param book table
---@param fallback_source table|nil
---@param with_reviews boolean|nil
function Cache.chooseRange(book, fallback_source, with_reviews)
    local pos = require("book.progress_db").get(book.source_id, book.stable_id) or {}
    local function from(count)
        return function()
            Cache.cacheAll(book, fallback_source,
                { chapter_idx = pos.chapter_idx, fraction = pos.fraction, count = count }, with_reviews)
        end
    end
    local function ahead(count)
        return { text = T(_("往后 %1 章"), count), callback = from(count) }
    end
    local items = {
        { text = _("全本缓存"), callback = function() Cache.cacheAll(book, fallback_source, nil, with_reviews) end },
        { text = _("从当前进度缓存到结尾"), callback = from(nil) },
        { buttons = { ahead(10), ahead(20) } },
        { buttons = { ahead(50), ahead(100) } },
    }
    local Prefetch = require("book.review_prefetch")
    if Prefetch.supported(bookOwnerSource(book, fallback_source)) then
        table.insert(items, 1, {
            text = (with_reviews and "[✓] " or "[  ] ") .. _("同时缓存段评（每句前 10 条）"),
            callback = function() Cache.chooseRange(book, fallback_source, not with_reviews) end,
        })
        if with_reviews then
            table.insert(items, 2, { widget = function(width)
                return require("ui.themes.widgets.text").box("body", _("段评请求频繁，可能导致账号被风控封号，请谨慎使用。"), width,
                    { bg = require("ui.themes").current().dialog.bg })
            end })
        end
    end
    require("ui.themes.widgets.sheet"):new{ title = _("缓存章节"), items = items }:show()
end

--- 缓存章节正文（可带段评）：入队并前台显示进度（同一本书已在缓存时拒绝并提示）。
---@param book table
---@param fallback_source table|nil
---@param range ChapterCacheRange|nil 缺省全本
---@param with_reviews boolean|nil 正文缓存完后接着缓存段评
function Cache.cacheAll(book, fallback_source, range, with_reviews)
    local source = bookOwnerSource(book, fallback_source)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, book = book }
    require("workers.ui.task_dialog").start{
        key = Cache.key(book),
        kind = "cache",
        title = book.title or book.stable_id,
        restartable = true,
        -- 已落盘章节重试时自动跳过，只重试服务端限流（425）与分片校验失败。
        retryable = function(result)
            local err = result.err or ""
            return err:find("HTTP 425", 1, true) ~= nil or err:find("shard md5 mismatch", 1, true) ~= nil
        end,
        on_done = Cache.notify,
        run = function(report, done)
            -- 句柄始终指向当前阶段：正文 → 段评。
            local stage
            local function reviews(result)
                if not (with_reviews and result.ok) then return done(result) end
                stage = require("book.review_prefetch").run(source, identity, range, function(n, total)
                    report(_("缓存段评"), n, total)
                end, function(ok, n, total, err)
                    result.reviews = { ok = ok, done = n, total = total, err = err }
                    done(result)
                end)
            end
            stage = source:cacheAllChaptersAsync(identity, function(cached, total)
                report(nil, cached, total)
            end, function(ok, cached, err, total, failed, failed_idx)
                reviews({ ok = ok, cached = cached, total = total, failed = failed, err = err, failed_idx = failed_idx })
            end, range)
            return { cancel = function() if stage then stage.cancel() end end }
        end,
    }
end

return Cache
