--[[-- ui.desktop.detail：底栏动作规划、标记已读、属主源删除。 --]]

local Assert = require("support.assert")

local function widgetModule()
    return {
        new = function(_, opts)
            opts = opts or {}
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = 10, h = 10 }
            end
            opts.free = function() end
            return opts
        end,
        extend = function(_, class)
            class.new = function(self, o)
                o = o or {}
                setmetatable(o, { __index = self })
                return o
            end
            return class
        end,
    }
end

for _, name in ipairs({
    "ui/widget/buttontable",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/topcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/linewidget",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
}) do
    package.preload[name] = widgetModule
end

package.preload["ui/widget/container/inputcontainer"] = function()
    return widgetModule()
end

local shown
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown = widget end,
        close = function() end,
        setDirty = function() end,
        nextTick = function(_, cb) cb() end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 800 end,
            getHeight = function() return 1000 end,
        },
        hasKeys = function() return false end,
    }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(v) return v end,
        face = function() return {} end,
        muted = function() return 0 end,
        surface = function() return 0 end,
        pagePad = function() return 16 end,
        line = function() return 1 end,
        rule = function() return 0 end,
        iconSz = function() return 24 end,
        progressBar = function() return { getSize = function() return { w = 10, h = 6 } end } end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function()
            return { getSize = function() return { w = 10, h = 10 } end }
        end,
    }
end
package.preload["ui.components.surface"] = function()
    return { build = function(opts) return opts.child end }
end
local strip_opts
package.preload["ui.components.pagestrip"] = function()
    return {
        bandH = function() return 40 end,
        clamp = function(page, pages)
            pages = math.max(1, math.floor(tonumber(pages) or 1))
            page = math.max(1, math.floor(tonumber(page) or 1))
            return math.min(page, pages), pages
        end,
        widget = function(opts)
            strip_opts = opts
            return {
                getSize = function()
                    return { w = opts.width, h = 40 }
                end,
            }
        end,
    }
end
local hero_opts
package.preload["ui.components.bookinfo"] = function()
    return {
        title = function(book) return book.title or "" end,
        author = function() return "" end,
        pct = function(book) return tonumber(book.percent) or 0 end,
        tappable = function(w, h, on_tap) return { w = w, h = h, on_tap = on_tap } end,
        hero = function(_, source, book, opts)
            hero_opts = { source = source, book = book, opts = opts }
            return { getSize = function() return { w = 100, h = 80 } end }, 80
        end,
        desc = function() return "" end,
    }
end
package.preload["book.catalog"] = function()
    return { formatDuration = function(s) return tostring(s) end }
end
package.preload["utils.text"] = function()
    return { trim = function(s) return s end }
end
local cleared
local clear_result = { true }
package.preload["book.store"] = function()
    return {
        rememberMany = function() end,
        isDownloaded = function(book) return book and book.downloaded == true end,
        clearCache = function(source_id, stable_id)
            cleared = { source_id, stable_id }
            return clear_result[1], clear_result[2]
        end,
    }
end
local queue_tasks = {}
package.preload["source.cache_queue"] = function()
    return { tasks = function() return queue_tasks end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return {
        template = function(s, value)
            return s:gsub("%%1", tostring(value))
        end,
    }
end
package.preload["utils.log"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local resolved
package.preload["source.registry"] = function()
    return {
        resolve = function(id)
            return resolved
        end,
        meta = function(id)
            if id == "wechat" then return { id = "wechat", name = "微信读书" } end
            if id == "local" then return { id = "local", name = "本地书籍" } end
            return { id = id, name = id }
        end,
    }
end

local set_read
local db_row
package.preload["db.book"] = function()
    return {
        setRead = function(source_id, stable_id, value)
            set_read = { source_id, stable_id, value }
            return true
        end,
        get = function()
            return db_row
        end,
    }
end

package.loaded["ui.desktop.detail"] = nil
package.loaded["ui.lifecycle"] = nil
local Detail = require("ui.desktop.detail")
local Lifecycle = require("ui.lifecycle")

local function ids(tools)
    local out = {}
    for i, item in ipairs(tools) do
        out[i] = item.id
    end
    return table.concat(out, ",")
end

local local_src = {
    id = "local",
    type = "book",
    capabilities = function()
        return { edit = true, scrape = true }
    end,
}
local chapter_src = {
    id = "wechat",
    type = "chapter",
    capabilities = function()
        return { edit = false, scrape = false }
    end,
    cacheAllChaptersAsync = function() end,
}

local unread = {
    source_id = "local",
    stable_id = "b1",
    title = "书一",
    read_state = 0,
    percent = 12,
}
local tools, primary = Detail.actionPlan(unread, local_src, "library")
Assert.eq(ids(tools), "edit,scrape,read,clear_cache,delete")
Assert.eq(primary.id, "open")
Assert.eq(primary.text, "继续阅读")

unread.percent = 0
_, primary = Detail.actionPlan(unread, local_src, "library")
Assert.eq(primary.text, "开始阅读")

local read_book = {
    source_id = "wechat",
    stable_id = "w1",
    title = "微信书",
    read_state = 1,
    percent = 100,
}
tools, primary = Detail.actionPlan(read_book, chapter_src, "library")
Assert.eq(ids(tools), "download,unread,clear_cache,delete")
Assert.eq(primary.text, "开始阅读")

read_book.downloaded = true
tools = Detail.actionPlan(read_book, chapter_src, "library")
Assert.eq(ids(tools), "unread,clear_cache,delete")

local page = setmetatable({
    book = {
        source_id = "wechat",
        stable_id = "w2",
        title = "书一",
        read_state = 0,
    },
    source = local_src,
    desktop = {
        library = { state = { stale = true }, page = 3 },
        lifecycle = { state = "Resume" },
    },
    updateView = function() end,
}, { __index = Detail })
page.lifecycle = Lifecycle.attach(page)
page:onCreate()
page:onResume()

page:toggleRead()
Assert.eq(set_read[1], "wechat")
Assert.eq(set_read[2], "w2")
Assert.is_true(set_read[3])
Assert.is_true(page._dirty)
Assert.is_nil(page.desktop.library.state)

page.book.read_state = 1
set_read = nil
page._dirty = nil
page.desktop.library.state = { stale = true }
page:toggleRead()
Assert.is_false(set_read[3])
Assert.is_true(page._dirty)

-- 清理缓存：确认后按身份清，成功重读并打脏；本书在后台缓存队列时拒绝
shown = nil
page._dirty = nil
page:clearCache()
Assert.eq(shown.text, "清理《书一》的本地缓存？\n正文、章节与图片需重新下载。")
shown.ok_callback()
Assert.eq(cleared[1], "wechat")
Assert.eq(cleared[2], "w2")
Assert.eq(shown.text, "缓存已清理")
Assert.is_true(page._dirty)

clear_result = { true, "partial" }
page:clearCache()
shown.ok_callback()
Assert.eq(shown.text, "部分缓存文件未能删除")

clear_result = { false }
page:clearCache()
shown.ok_callback()
Assert.eq(shown.text, "清理缓存失败")
clear_result = { true }

cleared = nil
queue_tasks = { { source_id = "wechat", stable_id = "w2" } }
page:clearCache()
shown.ok_callback()
Assert.is_nil(cleared)
Assert.eq(shown.text, "本书正在后台缓存，请稍后再试")
queue_tasks = {}

shown = nil
local deleted
resolved = {
    id = "wechat",
    type = "chapter",
    deleteBookAsync = function(_, identity, cb)
        deleted = identity
        cb(true)
    end,
}
page._dirty = nil
page.desktop.library.page = 4
page:deleteBook()
Assert.eq(shown.text, "确定删除《书一》？")
shown.ok_callback()
Assert.eq(deleted.source_id, "wechat")
Assert.eq(deleted.stable_id, "w2")
Assert.eq(deleted.source, resolved)
Assert.is_true(page._dirty)
Assert.eq(page.lifecycle.state, "Destroy")
Assert.eq(page.desktop.library.page, 1)

shown = nil
deleted = nil
resolved = {
    deleteBookAsync = function(_, _, cb)
        cb(false, "云端拒绝")
    end,
}
local page2 = setmetatable({
    book = {
        source_id = "wechat",
        stable_id = "w2",
        title = "书一",
        read_state = 0,
    },
    source = local_src,
    desktop = {
        library = { state = nil, page = 1 },
        lifecycle = { state = "Resume" },
    },
    updateView = function() end,
}, { __index = Detail })
page2.lifecycle = Lifecycle.attach(page2)
page2:onCreate()
page2:onResume()
page2:deleteBook()
shown.ok_callback()
Assert.eq(shown.text, "云端拒绝")
Assert.eq(page2.lifecycle.state, "Resume")

local recent = setmetatable({
    _daily = {
        { ymd = "2026-09-13", seconds = 60 },
        { ymd = "2026-09-12", seconds = 30 },
        { ymd = "2026-09-11", seconds = 10 },
    },
    _daily_page = 2,
    updateView = function(self) self.rebuilt = true end,
}, { __index = Detail })
strip_opts = nil
Assert.not_nil(recent:buildRecent(300, 80))
Assert.eq(recent._daily_page, 2)
Assert.eq(strip_opts.page, 2)
Assert.eq(strip_opts.pages, 3)
Assert.eq(strip_opts.width, 300)
strip_opts.on_prev()
Assert.eq(recent._daily_page, 1)
Assert.is_true(recent.rebuilt)
recent.rebuilt = false
recent:buildRecent(300, 80)
strip_opts.on_next()
Assert.eq(recent._daily_page, 2)

-- Hero 副文案带属主源名（混合模式同屏多源时可读）。
hero_opts = nil
resolved = { id = "wechat" }
local hero_page = setmetatable({
    plugin = {},
    source = { id = "local" },
    openBook = function() end,
}, { __index = Detail })
hero_page:buildHero(400, {
    source_id = "wechat",
    stable_id = "b1",
    title = "书",
    category = "科幻",
    series = "三体",
}, "library", true)
Assert.eq(hero_opts.opts.subtitle, "微信读书 · 科幻 · 三体")
Assert.eq(hero_opts.source.id, "wechat")
resolved = nil
