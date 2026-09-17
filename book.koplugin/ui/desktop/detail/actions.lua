--[[-- 书籍详情子模块。 @module ui.desktop.detail --]]

local BookInfo = require("ui.components.bookinfo")
local Store = require("book.store")
local _ = require("gettext")
local T = require("ffi/util").template


local Common = require("ui.desktop.detail.common")
local storeKind = Common.storeKind
local bookOwnerSource = Common.bookOwnerSource
local bookSupportsScrape = Common.bookSupportsScrape
local bookSupportsEdit = Common.bookSupportsEdit

return function(Detail)
function Detail:openBook()
    local plugin = self.plugin
    local b = self.book
    self:onClose()
    if plugin then require("book.open").book(plugin, b) end
end

--- 缓存章节模式整本正文。
---@return nil
function Detail:cacheAllChapters()
    if self._cache_job and not self._cache_job.done then return end
    if not self.lifecycle:uiReady() then return end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then return end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local job, queued = require("source.cache_queue").enqueue(source, {
        source_id = book.source_id,
        stable_id = book.stable_id,
        book = book,
    })
    if not job then return end
    self._cache_job = job
    UIManager:show(InfoMessage:new{
        text = queued and _("已加入后台缓存队列") or _("全本缓存任务已在后台运行"),
        timeout = 3,
    })
end

--- Z-Library 书：下载后导入本地书库。
---@return nil
function Detail:installStoreBook()
    local book = self.book or {}
    if self._install_job then
        return
    end
    if storeKind(book, self.source, self.origin) ~= "zlib" then
        return
    end
    if not require("zlib.init").hasCredentials() then
        require("zlib.setting").open(self.plugin)
        return
    end
    local local_src = require("source.registry").resolve("local")
    if not local_src or type(local_src.importBookAsync) ~= "function" then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("当前数据源不支持导入书籍"),
        })
        return
    end
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local dialog = ProgressbarDialog:new{
        title = _("正在加入书库…"),
        subtitle = book.title,
        progress_max = tonumber(book.filesize),
        dismissable = false,
    }
    dialog:show()
    require("ui/network/manager"):runWhenOnline(function()
        if not self.lifecycle:uiReady() then dialog:close(); return end
        self._install_job = self.lifecycle:addHttp(require("zlib.init").installAsync(local_src, book, function(bytes)
            dialog:reportProgress(bytes)
        end, function(ok, err, filename)
            self._install_job = nil
            dialog:close()
            if not self.lifecycle:uiReady() then return end
            if not ok then
                UIManager:show(InfoMessage:new{ text = err or _("下载失败") })
                return
            end
            local desk = self.desktop
            self:onClose()
            UIManager:show(InfoMessage:new{
                text = _("已加入书库：") .. tostring(filename or book.title),
                timeout = 3,
            })
            if desk and desk.lifecycle.state ~= "Destroy" then
                if desk.library then
                    desk.library.state = nil
                    desk.library.page = 1
                end
                desk:switchTab("library")
            end
        end))
    end)
end

--- 手动切换已读 / 未读（语义与图书馆长按菜单相同）。
---@return nil
function Detail:toggleRead()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    local is_read = tonumber(book.read_state) == 1
    if not require("db.book").setRead(book.source_id, book.stable_id, not is_read) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("更新阅读状态失败"),
            timeout = 2,
        })
        return
    end
    if not self.lifecycle:uiReady() then
        return
    end
    self:reload()
end

--- 删除本书：确认后走属主源 deleteBookAsync，成功则关详情并刷新桌面。
---@return nil
function Detail:deleteBook()
    local book = self.book
    if type(book) ~= "table" or type(book.source_id) ~= "string" or type(book.stable_id) ~= "string" then
        return
    end
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("确定删除《%1》？"), BookInfo.title(book)),
        ok_text = _("删除"),
        ok_callback = function()
            local source = bookOwnerSource(book, self.source)
            if not source or type(source.deleteBookAsync) ~= "function" then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("当前数据源不支持删除本书"),
                })
                return
            end
            source:deleteBookAsync({
                source_id = book.source_id,
                stable_id = book.stable_id,
                book = book,
                source = source,
            }, function(ok, err)
                if not ok then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = err or _("删除本书失败"),
                    })
                    return
                end
                if not self.lifecycle:uiReady() then
                    return
                end
                self._dirty = true
                local desk = self.desktop
                if desk and desk.library then
                    desk.library.state = nil
                    desk.library.page = 1
                end
                self:onClose()
            end)
        end,
    })
end

--- 库内书底栏动作：工具行 + 最后一行阅读主按钮。
--- 编辑/刮削/下载按属主源能力出现；已读切换与删除只要身份完整就给。
---@param book table 当前书籍
---@param owner table|nil 属主源
---@return table, table|nil tools, primary
function Detail.actionPlan(book, owner, origin)
    if origin == "store" then
        return {}, { id = "shelf", icon = "add", text = _("加入书库") }
    end
    local tools = {}
    if bookSupportsEdit(book, owner) then
        tools[#tools + 1] = { id = "edit", icon = "edit", text = _("编辑") }
    end
    if bookSupportsScrape(book, owner) then
        tools[#tools + 1] = { id = "scrape", icon = "search", text = _("刮削") }
    end
    local can_read = owner ~= nil and (owner.type == "book" or owner.type == "chapter")
    local can_cache = can_read and owner.type == "chapter"
        and type(owner.cacheAllChaptersAsync) == "function"
        and not Store.isDownloaded(book)
    if can_cache then
        tools[#tools + 1] = { id = "download", icon = "download", text = _("下载") }
    end
    if type(book) == "table" and type(book.source_id) == "string" and type(book.stable_id) == "string" then
        if tonumber(book.read_state) == 1 then
            tools[#tools + 1] = { id = "unread", icon = "undo", text = _("标记未读") }
        else
            tools[#tools + 1] = { id = "read", icon = "done_all", text = _("标记已读") }
        end
        tools[#tools + 1] = { id = "delete", icon = "delete", text = _("删除") }
    end
    local primary
    if can_read then
        local pct = BookInfo.pct(book)
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
    if type(book) ~= "table" then
        return
    end
    if not bookSupportsScrape(book, self.source) then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("当前数据源不支持刮削"),
            timeout = 2,
        })
        return
    end
    require("scrape.ui").start(book, book.title, function()
        self:reload()
    end)
end



end
