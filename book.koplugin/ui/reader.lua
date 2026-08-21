--[[--
阅读页动作与接线。

原生顶部菜单 Tab 和 Aa 菜单注入由 ui.reader.native 负责；本模块只定义
图标动作及其行为，并挂载阅读状态条，不拥有任何菜单布局。

@module koplugin.book.ui.reader
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Reader = {}

local function currentSession()
    return require("ui.reader.session").current()
end

local function showToc(ui)
    local session = require("ui.reader.session")
    local toc = session.toc()
    if not toc then
        if ui and ui.toc and ui.toc.onShowToc then
            ui.toc:onShowToc()
        end
        return
    end
    local current = session.current()
    local identity = current and current.identity
    local current_idx = identity and identity.chapter_idx
    local items = {}
    for _, chapter in ipairs(toc) do
        local idx = tonumber(chapter.idx) or 0
        items[#items + 1] = {
            text = chapter.title or ("#" .. idx),
            value = idx,
            checked = idx == current_idx,
        }
    end
    require("ui.components.popup").list{
        title = _("目录"),
        items = items,
        choice_icons = true,
        on_select = function(idx) session.gotoChapter(idx) end,
    }
end

local ACTIONS = {
    toc = {
        title = _("目录"),
        icon = "toc",
        available = function(ui)
            return require("ui.reader.session").toc() ~= nil
                or (ui and ui.toc and ui.toc.onShowToc ~= nil)
        end,
        run = showToc,
    },
    bookmark = {
        title = _("书签"),
        icon = "bookmark_border",
        available = function(ui)
            return ui and ui.bookmark and ui.bookmark.onToggleBookmark ~= nil
        end,
        active = function(ui)
            return ui and ui.bookmark and ui.bookmark.isPageBookmarked
                and ui.bookmark:isPageBookmarked() or false
        end,
        run = function(ui)
            ui.bookmark:onToggleBookmark()
        end,
        keep_open = true,
    },
    highlights = {
        title = _("高亮与笔记"),
        icon = "format_quote",
        available = function(ui)
            return ui and ui.bookmark and ui.bookmark.onShowBookmark ~= nil
        end,
        run = function(ui)
            ui.bookmark:onShowBookmark()
        end,
    },
    sync = {
        title = _("同步"),
        icon = "sync",
        available = function()
            local current = currentSession()
            return current and current.identity and current.identity.source ~= nil
        end,
        run = function(ui)
            local current = currentSession()
            local identity = current and current.identity
            local source = identity and identity.source
            if not ui or not identity or not source then return end
            require("book.progress").save(current, function(progress_ok)
                if not progress_ok then return end
                require("book.note").save(ui, identity, function(notes_ok)
                    if not notes_ok then return end
                    require("book.sync").runAsync(source, {
                        identity = identity,
                        skip_books = true,
                    }, function(result, err)
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = result and _("同步完成")
                                or (err and tostring(err) or _("同步失败")),
                            timeout = 2,
                        })
                    end)
                end)
            end)
        end,
    },
    ocr = {
        title = _("OCR"),
        icon = "document_scanner",
        available = function(ui)
            return ui ~= nil
        end,
        run = function(ui)
            require("ui.reader.ocr").open(ui)
        end,
    },
    dictionary = {
        title = _("字典"),
        icon = "book",
        available = function(ui)
            return ui and ui.dictionary ~= nil
        end,
        run = function(ui)
            require("ui.reader.dictionary").open(ui)
        end,
    },
    ai_analysis = {
        title = _("AI 分析"),
        icon = "psychology",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("ui.reader.ai").open(ui, "analysis") end,
    },
    ai_summary = {
        title = _("AI 总结"),
        icon = "summarize",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("ui.reader.ai").open(ui, "summary") end,
    },
    ai_graph = {
        title = _("关系图谱"),
        icon = "account_tree",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("ui.reader.ai").open(ui, "graph") end,
    },
    xray_characters = {
        title = _("人物"),
        icon = "person",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("xray.ui").open(ui, "characters") end,
    },
    xray_locations = {
        title = _("地点"),
        icon = "place",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("xray.ui").open(ui, "locations") end,
    },
    xray_timeline = {
        title = _("时间线"),
        icon = "timeline",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("xray.ui").open(ui, "timeline") end,
    },
    xray_lookup = {
        title = _("X-Ray 查询"),
        icon = "search",
        available = function() return currentSession() ~= nil end,
        run = function(ui) require("xray.ui").lookup(ui) end,
    },
}

local ACTION_ORDER = {
    "toc", "bookmark", "highlights", "sync", "ocr", "dictionary",
    "ai_analysis", "ai_summary", "ai_graph",
    "xray_characters", "xray_locations", "xray_timeline", "xray_lookup",
}

--- 当前阅读页的图标动作；原生 Tab 每次重绘都重新取状态。
---@param ui table|nil
---@return table[]
function Reader.actions(ui)
    local result = {}
    for _, id in ipairs(ACTION_ORDER) do
        local action = ACTIONS[id]
        result[#result + 1] = {
            id = id,
            title = action.title,
            icon = action.active and action.active(ui) and "bookmark" or action.icon,
            active = action.active and action.active(ui) or false,
            enabled = not action.available or action.available(ui),
            keep_open = action.keep_open == true,
        }
    end
    return result
end

--- 执行顶部图标动作。
---@param id string
---@param ui table|nil
---@param opts { close: fun()|nil, refresh: fun()|nil }|nil
---@return boolean
function Reader.executeAction(id, ui, opts)
    local action = ACTIONS[id]
    if not action or (action.available and not action.available(ui)) then
        return false
    end
    opts = opts or {}
    if not action.keep_open and opts.close then opts.close() end
    action.run(ui)
    if action.keep_open and opts.refresh then opts.refresh() end
    return true
end

--- 给当前 ReaderUI 安装原生菜单注入和阅读状态条。
---@param plugin table
function Reader.attach(plugin)
    local ui = plugin and plugin.ui
    if not ui or ui._book_reader_attached then return end
    ui._book_reader_attached = true

    require("ui.reader.native").install(ui)
    if ui.view and ui.view.registerViewModule then
        local bars = require("ui.reader.bars")
        ui.view:registerViewModule("book_bars", bars)
        bars:startClock()
    end
    require("lockscreen.init").refreshInBackground(true)
end

---@param plugin table
function Reader.refresh(plugin)
    local ui = plugin and plugin.ui
    if ui then UIManager:setDirty(ui.dialog, "ui") end
    local LockScreen = require("lockscreen.init")
    local force = LockScreen.needsLiveRefresh and LockScreen.needsLiveRefresh()
    LockScreen.refreshInBackground(force)
end

return Reader
