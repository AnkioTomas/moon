--[[-- 书籍详情子模块。 @module desktop.detail --]]

local Book = require("ui.widgets.book")
local Confirm = require("ui.themes.widgets.confirm")
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")
local Store = require("book.store")
local _ = require("gettext")
local T = require("ffi/util").template


local Common = require("desktop.detail.common")
local storeBackend = Common.storeBackend
local bookOwnerSource = Common.bookOwnerSource
local bookSupportsScrape = Common.bookSupportsScrape
local bookSupportsEdit = Common.bookSupportsEdit

---@param book table
---@return string
local function cacheKey(book)
    return "cache\0" .. book.source_id .. "\0" .. book.stable_id
end

--- 章节缓存结果提示：成功 / 部分完成 / 失败。
---@param result { ok: boolean, cached: integer, total: integer, failed: integer, err: string|nil, failed_idx: integer[]|nil, reviews?: { ok: boolean, done: integer, err?: string } }
local function notifyCached(result)
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

return function(Detail)
function Detail:openBook()
    local plugin = self.plugin
    local b = self.book
    self:close()
    if plugin then require("desktop.open").book(plugin, b) end
end

--- 选择缓存范围：全本 / 当前进度到结尾 / 当前进度往后 N 章（当前章取本地进度，无进度即第 1 章）。
--- 源支持段评时多一个开关：同时缓存段评（每句只缓存前 10 条评论，请求频繁有封号风险）。
function Detail:chooseCacheRange(with_reviews)
    if self.closed then return end
    local book = self.book
    local pos = require("book.progress_db").get(book.source_id, book.stable_id) or {}
    local function from(count)
        return function()
            self:cacheAllChapters({ chapter_idx = pos.chapter_idx, fraction = pos.fraction, count = count }, with_reviews)
        end
    end
    local function ahead(count)
        return { text = T(_("往后 %1 章"), count), callback = from(count) }
    end
    local items = {
        { text = _("全本缓存"), callback = function() self:cacheAllChapters(nil, with_reviews) end },
        { text = _("从当前进度缓存到结尾"), callback = from(nil) },
        { buttons = { ahead(10), ahead(20) } },
        { buttons = { ahead(50), ahead(100) } },
    }
    local Prefetch = require("book.review_prefetch")
    if Prefetch.supported(bookOwnerSource(book, self.source)) then
        table.insert(items, 1, {
            text = (with_reviews and "[✓] " or "[  ] ") .. _("同时缓存段评（每句前 10 条）"),
            callback = function() self:chooseCacheRange(not with_reviews) end,
        })
        if with_reviews then
            table.insert(items, 2, { widget = function(width)
                return require("ui.themes.widgets.text").box("body", _("段评请求频繁，可能导致账号被风控封号，请谨慎使用。"), width)
            end })
        end
    end
    require("ui.themes.widgets.sheet"):new{ title = _("缓存章节"), items = items }:show()
end

--- 缓存章节正文（可带段评）：入队并前台显示进度（同一本书已在缓存时拒绝并提示）。
---@param range ChapterCacheRange|nil 缺省全本
---@param with_reviews boolean|nil 正文缓存完后接着缓存段评
function Detail:cacheAllChapters(range, with_reviews)
    if self.closed then return end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, book = book }
    require("workers.ui.task_dialog").start{
        key = cacheKey(book),
        kind = "cache",
        title = book.title or book.stable_id,
        restartable = true,
        -- 已落盘章节重试时自动跳过，只重试服务端限流（425）与分片校验失败。
        retryable = function(result)
            local err = result.err or ""
            return err:find("HTTP 425", 1, true) ~= nil or err:find("shard md5 mismatch", 1, true) ~= nil
        end,
        on_done = notifyCached,
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

--- 整本书源的未下载书（WebDAV、moon）：入队只落盘不开书，openBookAsync 负责下载并登记路径。
function Detail:downloadBook()
    if self.closed then return end
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, source = source, book = book }
    require("workers.ui.task_dialog").start{
        key = cacheKey(book),
        kind = "cache",
        title = book.title or book.stable_id,
        on_done = function(result)
            Toast:new{ text = result.ok and _("下载完成") or (result.err or _("下载失败")), timeout = 3 }:show()
            if not result.ok then return end
            if self.desktop then self.desktop:onEvent("shelf_changed") end
            if not self.closed then self:reload() end
        end,
        run = function(_report, done)
            return source:openBookAsync(identity, nil, function(path, err)
                done({ ok = path ~= nil, err = err })
            end)
        end,
    }
end

--- 书城书（Z-Library / OPDS）：进后台下载任务，下载后导入本地书库；详情页关了也继续。
function Detail:installStoreBook()
    local book = self.book
    local store = storeBackend(book)
    if not store then
        self:addToShelf()
        return
    end
    if store.hasCredentials and not store.hasCredentials() then
        require("store." .. book.source_id .. ".setting").open(self.plugin)
        return
    end
    local local_src = require("source.registry").resolve("local")
    if local_src and not local_src:configured() then
        require("source.local.setting").open(function() self:installStoreBook() end)
        return
    end
    if not local_src or type(local_src.importBookAsync) ~= "function" then
        Toast:new{ text = _("当前数据源不支持导入书籍") }:show()
        return
    end
    local desk = self.desktop
    local total = tonumber(book.filesize)
    require("workers.ui.task_dialog").start{
        key = "install\0" .. tostring(book.source_id) .. "\0" .. tostring(book.stable_id),
        kind = "download",
        title = book.title,
        restartable = true,
        run = function(report, done)
            return store.installAsync(local_src, book, function(bytes)
                report(nil, bytes, total)
            end, function(ok, err, filename)
                done({ ok = ok, err = err, filename = filename })
            end)
        end,
        on_done = function(result)
            if not result.ok then
                Toast:new{ text = result.err or _("下载失败") }:show()
                return
            end
            Toast:new{
                text = _("已加入书库：") .. tostring(result.filename or book.title),
                timeout = 3,
            }:show()
            if desk and not desk.closed then
                desk:onEvent("shelf_changed")
                if desk.tab == "library" then desk:updateView() end
            end
        end,
    }
end

--- 书源搜索结果：本地先入库（脏行），在线且源已配置时顺手推上云端书架；离线不弹联网，等下次 pushDirty。
function Detail:addToShelf()
    local book = self.book
    Store.rememberMany({ book })
    if not require("book.books_db").upsertLocal(book) then
        Toast:new{ text = _("加入书库失败") }:show()
        return
    end
    Toast:new{ text = T(_("已加入书库：%1"), Book.title(book)), timeout = 3 }:show()
    local source = bookOwnerSource(book, nil)
    if source and source:configured() and require("ui/network/manager"):isConnected() then
        source:pushDirty()
    end
    local desk = self.desktop
    if desk and not desk.closed then desk:onEvent("shelf_changed") end
end

--- 手动切换已读 / 未读（语义与图书馆长按菜单相同）。
function Detail:toggleRead()
    local book = self.book
    local is_read = tonumber(book.read_state) == 1
    if not require("book.books_db").setRead(book.source_id, book.stable_id, not is_read) then
        Toast:new{ text = _("更新阅读状态失败"), timeout = 2 }:show()
        return
    end
    -- 标已读会写一条 100% 待上传进度：在线就当场推，不等下一次推脏行。
    local source = bookOwnerSource(book, self.source)
    if source and require("ui/network/manager"):isConnected() then
        source:syncProgressAsync({
            identity = { source_id = book.source_id, stable_id = book.stable_id, book = book, source = source },
            dirty_only = true,
        }, function() end)
    end
    self:reload()
end

--- 删除本书：先选软删除（书留库里、默认隐藏）还是彻底删除。
function Detail:deleteBook()
    Sheet:new{
        title = _("删除"),
        items = {
            { text = _("软删除（隐藏，数据保留，可恢复）"), callback = function() self:softDelete() end },
            { text = _("彻底删除（连同书架条目与进度一并移除）"), callback = function() self:hardDelete() end },
        },
    }:show()
end

--- 彻底删除：确认后走属主源 deleteBookAsync，成功则关详情并刷新桌面。
function Detail:hardDelete()
    local book = self.book
    Confirm:new{
        text = T(_("确定删除《%1》？"), Book.title(book)),
        ok_text = _("删除"),
        ok_callback = function()
            local source = bookOwnerSource(book, self.source)
            if not source then
                Toast:new{ text = _("当前数据源不支持删除本书") }:show()
                return
            end
            source:deleteBookAsync({
                source_id = book.source_id,
                stable_id = book.stable_id,
                book = book,
                source = source,
            }, function(ok, err)
                if not ok then
                    Toast:new{ text = err or _("删除本书失败") }:show()
                    return
                end
                -- 书已删：书架缓存无论详情页是否还开着都要失效。
                if self.desktop then self.desktop:onEvent("shelf_changed") end
                if self.closed then return end
                self._dirty = true
                self:close()
            end)
        end,
    }:show()
end

--- 清理本书本地文件：keep_cover 为真保留封面；书籍元数据与进度保留。
--- 本书在后台缓存队列里时拒绝，避免边写边删。
---@param self table
---@param keep_cover boolean
---@param text string 确认文案
---@param ok_text string
---@param done_text string
local function purgeLocal(self, keep_cover, text, ok_text, done_text)
    local book = self.book
    Confirm:new{
        text = T(text, Book.title(book)),
        ok_text = ok_text,
        ok_callback = function()
            if require("workers.tasks").get(cacheKey(book)) then
                Toast:new{ text = _("本书正在后台缓存，请稍后再试"), timeout = 3 }:show()
                return
            end
            local ok, leftover = Store.clearCache(book.source_id, book.stable_id, keep_cover)
            local result = done_text
            if not ok then
                result = _("清理缓存失败")
            elseif leftover then
                result = _("部分缓存文件未能删除")
            end
            Toast:new{ text = result, timeout = 3 }:show()
            self:reload()
        end,
    }:show()
end

--- 清理本书本地缓存：正文、章节、图片、封面需重新下载；书籍元数据与进度保留。
function Detail:clearCache()
    purgeLocal(self, false, _("清理《%1》的本地缓存？\n正文、章节与图片需重新下载。"), _("清理"), _("缓存已清理"))
end

--- 软删除：清掉本地文档，书留在库里（元数据、封面、进度、标注都在），默认不在书架显示，
--- 在书架筛选「软删除」里能找到并恢复。纯本地操作，不动远端。
function Detail:softDelete()
    local book = self.book
    Confirm:new{
        text = T(_("软删除《%1》？\n本地文档会被清理，书从书架隐藏，数据保留，可在筛选「软删除」中恢复。"), Book.title(book)),
        ok_text = _("软删除"),
        ok_callback = function()
            if require("workers.tasks").get(cacheKey(book)) then
                Toast:new{ text = _("本书正在后台缓存，请稍后再试"), timeout = 3 }:show()
                return
            end
            local ok = Store.clearCache(book.source_id, book.stable_id, true)
            if not (ok and require("book.books_db").setHidden(book.source_id, book.stable_id, true)) then
                Toast:new{ text = _("软删除失败"), timeout = 3 }:show()
                return
            end
            Toast:new{ text = _("已软删除"), timeout = 2 }:show()
            if self.desktop then self.desktop:onEvent("shelf_changed") end
            if self.closed then return end
            self._dirty = true
            self:close()
        end,
    }:show()
end

--- 恢复软删除的书：重新出现在书架，文档需要时再下载。
function Detail:restore()
    if not require("book.books_db").setHidden(self.book.source_id, self.book.stable_id, false) then
        Toast:new{ text = _("恢复失败"), timeout = 2 }:show()
        return
    end
    Toast:new{ text = _("已恢复到书架"), timeout = 2 }:show()
    self:reload()
end

--- 库内书底栏动作：工具行 + 最后一行阅读主按钮。
--- 编辑/刮削/下载/清理缓存按属主源能力出现；已读切换与删除只要身份完整就给。
---@param book table 当前书籍
---@param owner table|nil 属主源
---@return table tools, table|nil primary
function Detail.actionPlan(book, owner)
    local tools = {}
    if bookSupportsEdit(book, owner) then
        tools[#tools + 1] = { id = "edit", icon = "edit", text = _("编辑") }
    end
    if bookSupportsScrape(book, owner) then
        tools[#tools + 1] = { id = "scrape", icon = "search", text = _("刮削") }
    end
    local can_read = owner ~= nil and (owner.type == "book" or owner.type == "chapter")
    -- 章节源能缓存就一直给下载（「已下载」只看当前章起连续，缓存一段后后面仍可能要缓存），
    -- 已离线到 cache 再给清理；整本书源下载与清理互斥；本地原书（path 即文件本身）两者都没有
    local cached = can_read and Store.isCached(book)
    if can_read and owner.type == "chapter" and type(owner.cacheAllChaptersAsync) == "function" then
        tools[#tools + 1] = { id = "download", icon = "download", text = _("下载") }
    elseif can_read and not cached and owner.type == "book" and book.source_id and book.stable_id
        and not require("book.books_db").isDownloaded(book.source_id, book.stable_id, false) then
        tools[#tools + 1] = { id = "download_book", icon = "download", text = _("下载") }
    end
    if cached then
        tools[#tools + 1] = { id = "clear_cache", icon = "cleaning_services", text = _("清理缓存") }
    end
    if book.source_id and book.stable_id then
        if tonumber(book.read_state) == 1 then
            tools[#tools + 1] = { id = "unread", icon = "undo", text = _("未读") }
        else
            tools[#tools + 1] = { id = "read", icon = "done_all", text = _("已读") }
        end
        if tonumber(book.hidden) == 1 then
            tools[#tools + 1] = { id = "restore", icon = "restore_from_trash", text = _("恢复") }
        end
        tools[#tools + 1] = { id = "delete", icon = "delete", text = _("删除") }
    end
    local primary
    if can_read then
        local pct = Book.pct(book)
        primary = {
            id = "open",
            icon = "play_arrow",
            text = pct > 0 and pct < 100 and _("继续阅读") or _("开始阅读"),
        }
    end
    return tools, primary
end

function Detail:startScrape()
    local book = self.book
    if not bookSupportsScrape(book, self.source) then
        Toast:new{ text = _("当前数据源不支持刮削"), timeout = 2 }:show()
        return
    end
    require("desktop.detail.scrape.ui").start(book, book.title, function()
        if not self.closed then self:reload() end
    end, self)
end



end
