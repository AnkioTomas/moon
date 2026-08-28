--[[--
ui.desktop.home 离线用例：布局默认、裁剪、pager 与 enrich。

@module tests.ui.desktop.home.layout_spec
--]]

local Assert = require("support.assert")

local home_settings = {
    home_layout = { "recent_list" },
    home_recent_list_mode = "hero_grid",
    home_excerpt_index = 0,
}
package.preload["utils.settings"] = function()
    return {
        get = function(section)
            if section == "home" then return home_settings end
            return home_settings
        end,
        saveSection = function(_, section, values)
            if section == "home" then home_settings = values end
        end,
    }
end

package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end

local build_log = {}
local layout_kids = {}

local function widgetStub()
    return {
        new = function(_, opts)
            if opts and opts.align then
                layout_kids = opts
                return opts
            end
            return opts or {}
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end
package.preload["ui/widget/container/framecontainer"] = widgetStub
package.preload["ui/geometry"] = widgetStub
package.preload["ui/widget/verticalgroup"] = widgetStub
package.preload["ui/widget/verticalspan"] = widgetStub
package.preload["ui.components.bookui"] = function()
    return { sz = function(n) return n end }
end
package.preload["ui.components.pager"] = function()
    return {
        bandH = function() return 20 end,
        band = function(w, page, pages)
            return { _pager = true, w = w, page = page, pages = pages }
        end,
    }
end

local function stubComponent(id, height, extra)
    return {
        id = id,
        label = id,
        build = function(_ctx, _state, opts)
            local entry = {
                id = id,
                budget = opts.budget,
                recent_mode = opts.recent_mode,
            }
            if extra then
                for k, v in pairs(extra) do entry[k] = v end
            end
            build_log[#build_log + 1] = entry
            local part = { widget = { _id = id }, height = height }
            if extra and extra.pager then
                part.pager = extra.pager
            end
            return part
        end,
    }
end

for _, spec in ipairs({
    { "clock", 50 },
    { "stats", 40 },
    { "hitokoto", 30 },
    { "excerpt", 35 },
    { "recent_list", 120, {
        pager = { page = 2, pages = 5, handlers = {} },
    }},
    { "recent_cards", 200 },
}) do
    local id, height, extra = spec[1], spec[2], spec[3]
    package.preload["ui.desktop.home.components." .. id] = function()
        return stubComponent(id, height, extra)
    end
end

local progress_rows = {}
package.preload["utils.db.progress"] = function()
    return {
        get = function(source_id, stable_id)
            return progress_rows[source_id .. "\0" .. stable_id]
        end,
    }
end

local Base = require("ui.desktop.home.components.base")
local Enrich = require("ui.desktop.home.enrich")
local HomeStats = require("ui.desktop.home.stats")
local Layout = require("ui.desktop.home.layout")

Assert.eq(#Base.enabledLayout(), 1)
Assert.eq(Base.enabledLayout()[1], "recent_list")

home_settings.home_layout = { "clock", "stats", "unknown", "recent_list" }
local layout = Base.enabledLayout()
Assert.eq(#layout, 3)
Assert.eq(layout[1], "clock")
Assert.eq(layout[3], "recent_list")

progress_rows["moon\0book-1"] = {
    chapter_title = "第一章 开端",
    chapter_idx = 2,
    fraction = 0.42,
}
local book = Enrich.book({
    source_id = "moon",
    stable_id = "book-1",
    title = "测试书",
    percent = 10,
})
Assert.eq(book.chapter_title, "第一章 开端")
Assert.eq(book.chapter_idx, 2)
Assert.eq(book.percent, 42)

local daily = {
    { ymd = os.date("%Y-%m-%d"), seconds = 600 },
    { ymd = os.date("%Y-%m-%d", os.time() - 86400), seconds = 300 },
    { ymd = os.date("%Y-%m-%d", os.time() - 2 * 86400), seconds = 0 },
}
Assert.eq(HomeStats.currentStreak(daily), 2)

local broken = {
    { ymd = os.date("%Y-%m-%d"), seconds = 0 },
    { ymd = os.date("%Y-%m-%d", os.time() - 86400), seconds = 100 },
}
Assert.eq(HomeStats.currentStreak(broken), 1)

-- Layout.build：预算不足时裁剪后续组件
build_log = {}
layout_kids = {}
home_settings.home_layout = { "clock", "stats", "recent_list" }
home_settings.home_recent_list_mode = "hero_grid"
Layout.build({ width = 320, height = 90 }, {})
Assert.eq(#build_log, 2)
Assert.eq(build_log[1].id, "clock")
Assert.eq(build_log[2].id, "stats")
Assert.eq(#layout_kids, 1)

-- Layout.build：唯一 recent_list → footer_full + 底部分页条
build_log = {}
layout_kids = {}
home_settings.home_layout = { "recent_list" }
Layout.build({ width = 320, height = 200 }, {})
Assert.eq(#build_log, 1)
Assert.eq(build_log[1].recent_mode, "footer_full")
Assert.eq(#layout_kids, 3)
Assert.is_true(layout_kids[3]._pager)
Assert.eq(layout_kids[3].page, 2)

-- Layout.build：纯列表末位 recent_list → footer_tail
build_log = {}
layout_kids = {}
home_settings.home_layout = { "clock", "recent_list" }
home_settings.home_recent_list_mode = "list_only"
Layout.build({ width = 320, height = 200 }, {})
Assert.eq(#build_log, 2)
Assert.eq(build_log[1].recent_mode, nil)
Assert.eq(build_log[2].recent_mode, "footer_tail")
Assert.is_true(layout_kids[#layout_kids]._pager)

-- Layout.build：inline 模式不分页条
build_log = {}
layout_kids = {}
home_settings.home_layout = { "clock", "recent_list" }
home_settings.home_recent_list_mode = "hero_grid"
Layout.build({ width = 320, height = 200 }, {})
Assert.eq(build_log[2].recent_mode, "inline")
Assert.is_nil(layout_kids[#layout_kids]._pager)

return true
