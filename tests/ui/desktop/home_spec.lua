--[[--
首页拼装器：钉页、编辑态、翻页生命周期。

@module tests.ui.desktop.home_spec
--]]

local Assert = require("support.assert")
local Lifecycle = require("ui.view")
local child_events = {}

local Clock = setmetatable({ id = "clock" }, Lifecycle)
Clock.__index = Clock
function Clock:onCreate() child_events[#child_events + 1] = "create" end
function Clock:onStart() child_events[#child_events + 1] = "start" end
function Clock:onPause() child_events[#child_events + 1] = "pause" end
function Clock:onResume() child_events[#child_events + 1] = "resume" end
function Clock:onStop() child_events[#child_events + 1] = "stop" end
function Clock:onDestroy() child_events[#child_events + 1] = "destroy" end
function Clock:build()
    return { widget = { id = "clock" } }
end
local clock_h = 10
function Clock:heightRange()
    return { height = clock_h }
end

local Weather = setmetatable({ id = "weather" }, Lifecycle)
Weather.__index = Weather
function Weather:onCreate() child_events[#child_events + 1] = "weather.create" end
function Weather:onStart() child_events[#child_events + 1] = "weather.start" end
function Weather:onPause() child_events[#child_events + 1] = "weather.pause" end
function Weather:onResume() child_events[#child_events + 1] = "weather.resume" end
function Weather:onStop() child_events[#child_events + 1] = "weather.stop" end
function Weather:onDestroy() child_events[#child_events + 1] = "weather.destroy" end
function Weather:build()
    return { widget = { id = "weather" } }
end
function Weather:heightRange()
    return { height = 10 }
end

local enabled = { "clock" }
local placements = {
    { id = "clock", page = 1, order = 1, height = "default" },
}
local can_fit = true
local last_strip
local last_add
package.preload["ui.desktop.home.registry"] = function()
    return {
        components = { Clock, Weather },
        find = function(id)
            if id == "clock" then return Clock end
            if id == "weather" then return Weather end
        end,
        enabledLayout = function() return enabled end,
        widgets = function() return placements end,
        saveWidgets = function(list)
            placements = list
            enabled = {}
            for _, item in ipairs(list) do enabled[#enabled + 1] = item.id end
        end,
        needsSplit = function() return false end,
        clearNeedsSplit = function() end,
    }
end
package.preload["ui.desktop.home.widgets"] = function()
    return {
        pageCount = function(list)
            local max_p = 1
            for _, item in ipairs(list) do
                if item.page > max_p then max_p = item.page end
            end
            return max_p
        end,
        onPage = function(list, page)
            local out = {}
            for _, item in ipairs(list) do
                if item.page == page then out[#out + 1] = item end
            end
            return out
        end,
        find = function(list, id)
            for i, item in ipairs(list) do
                if item.id == id then return item, i end
            end
        end,
        compactPages = function(list) return list end,
        reindex = function(list) return list end,
        canFit = function() return can_fit end,
        appendSlot = function(list, current, fits)
            if fits then
                local n = 0
                for _, item in ipairs(list) do
                    if item.page == current then n = n + 1 end
                end
                return current, n + 1
            end
            local max_p = 1
            for _, item in ipairs(list) do
                if item.page > max_p then max_p = item.page end
            end
            return max_p + 1, 1
        end,
        applyPacks = function(list) return list end,
        ids = function(list)
            local out = {}
            for _, item in ipairs(list) do out[#out + 1] = item.id end
            return out
        end,
    }
end
package.preload["book.cache"] = function()
    return { cleanupStaleAsync = function() return { cancel = function() end } end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["book.catalog"] = function()
    return {
        recentBooks = function() return {} end,
        recentShelf = function() return nil, {}, nil end,
    }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end } }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui.components.bookui"] = function()
    return {
        topBarH = function() return 30 end,
        sz = function(n) return n end,
        face = function() return {} end,
        pagePad = function() return 16 end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 200 }
end
local layout_pages = 1
package.preload["ui.desktop.home.layout"] = function()
    return {
        new = function()
            return {
                paginate = function() return { {} } end,
                build = function(_, _, components, page, opts)
                    local pages = layout_pages
                    page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
                    local visible = {}
                    if #enabled <= 1 or pages <= 1 then
                        for i = 1, #enabled do visible[enabled[i]] = true end
                        return {
                            kid = components[enabled[1] or "clock"],
                            dimen = { w = 600, h = (opts and opts.body_height) or 360 },
                        }, page, pages, visible
                    end
                    local shown = page == 1 and enabled[1] or enabled[2]
                    visible[shown] = true
                    return {
                        kid = components[shown],
                        dimen = { w = 600, h = (opts and opts.body_height) or 360 },
                    }, page, pages, visible
                end,
            }
        end,
    }
end
package.preload["ui.components.pagestrip"] = function()
    return {
        bandH = function() return 40 end,
        widget = function(opts)
            last_strip = opts
            return { strip = true, page = opts.page, pages = opts.pages, center = opts.center }
        end,
    }
end
package.preload["ui.desktop.home.edit_overlay"] = function()
    return {
        wrap = function(widget) return { edited = true, widget = widget } end,
        addRow = function() return { add = true } end,
        showMoveDialog = function() end,
        showHeightDialog = function() end,
        showAddDialog = function(candidates, on_pick)
            last_add = { candidates = candidates, on_pick = on_pick }
        end,
    }
end
local function widgetStub()
    return {
        new = function(_, opts)
            opts = opts or {}
            opts.getSize = function(self) return self.dimen or { w = 600, h = 400 } end
            return opts
        end,
    }
end
package.preload["ui.components.icon"] = function()
    return { widget = function(opts) return { name = opts.name, dim = opts.dim } end }
end
package.preload["ui/widget/overlapgroup"] = widgetStub
package.preload["ui/widget/container/framecontainer"] = widgetStub
package.preload["ui/widget/horizontalgroup"] = widgetStub
package.preload["ui/widget/verticalgroup"] = widgetStub
package.preload["ui/widget/verticalspan"] = widgetStub
package.preload["ui/widget/container/centercontainer"] = widgetStub
package.preload["ui/widget/container/inputcontainer"] = widgetStub
package.preload["ui/gesturerange"] = widgetStub

local Home = require("ui.desktop.home")
local desktop = {
    lifecycle = { state = "Resume" },
    tab = "home",
    source = { id = "local" },
    contentHeight = function() return 400 end,
    ctx = function(self)
        return { width = 600, height = 400, desktop = self, source = self.source }
    end,
}
local home = Home:new({ desktop = desktop })
desktop.home = home
Assert.eq(home.lifecycle.state, "new")
Assert.is_nil(home.components)
home:onCreate()
Assert.eq(home.lifecycle.state, "Create")
Assert.not_nil(home.components.clock)
Assert.eq(home.components.clock.lifecycle.state, "Create")
Assert.not_nil(home.widget)

home:onResume()
Assert.eq(home.lifecycle.state, "Resume")
Assert.eq(home.components.clock.lifecycle.state, "Resume")

-- 设置改布局：关掉的走完关闭生命周期。
enabled = {}
placements = {}
child_events = {}
home:onEvent("home_changed")
Assert.is_nil(home.components.clock)
Assert.eq(table.concat(child_events, ","), "pause,stop,destroy")

enabled = { "clock" }
placements = { { id = "clock", page = 1, order = 1, height = "default" } }
home:onEvent("home_changed")
child_events = {}
home:onEvent("source_changed")
Assert.eq(table.concat(child_events, ""), "")

-- 换源必须先更新已构建子组件的上下文，再交给组件重建。
local next_source = { id = "wechat" }
home.components.clock.ctx = { source = desktop.source }
home:onEvent("source_changed", next_source)
Assert.eq(home.source, next_source)
Assert.eq(home.components.clock.ctx.source, next_source)

-- PageStrip 翻页；越界不重建。
layout_pages = 3
placements = {
    { id = "clock", page = 1, order = 1, height = "default" },
}
enabled = { "clock" }
home.page = 1
home:updateView()
Assert.eq(home.page, 1)
Assert.eq(home.pages, 3)
Assert.is_true(home.widget[1] ~= nil)
home:turn(1)
Assert.eq(home.page, 2)
home:onEvent("swipe", { direction = "west" })
Assert.eq(home.page, 3)
home:turn(1)
Assert.eq(home.page, 3)
home:onEvent("swipe", { direction = "east" })
Assert.eq(home.page, 2)
home:turn(-10)
Assert.eq(home.page, 1)
layout_pages = 1
home:updateView()
Assert.eq(home.page, 1)
Assert.eq(home.pages, 1)

-- 翻页：当前页 Resume，离开的页 onPause。非当前页停在 Create。
enabled = { "clock", "weather" }
placements = {
    { id = "clock", page = 1, order = 1, height = "default" },
    { id = "weather", page = 2, order = 1, height = "default" },
}
layout_pages = 2
home.page = 1
child_events = {}
home:updateView()
Assert.eq(home.components.clock.lifecycle.state, "Resume")
Assert.eq(home.components.weather.lifecycle.state, "Create")
Assert.eq(table.concat(child_events, ","), "weather.create")
child_events = {}
home:turn(1)
Assert.eq(home.page, 2)
Assert.eq(home.components.clock.lifecycle.state, "Pause")
Assert.eq(home.components.weather.lifecycle.state, "Resume")
Assert.eq(table.concat(child_events, ","), "pause,weather.start,weather.resume")
child_events = {}
home:turn(-1)
Assert.eq(home.components.clock.lifecycle.state, "Resume")
Assert.eq(home.components.weather.lifecycle.state, "Pause")
Assert.eq(table.concat(child_events, ","), "weather.pause,resume")

-- 编辑态：底栏「添加 / 完成」；当前页塞不下则新建页。
enabled = { "clock" }
placements = { { id = "clock", page = 1, order = 1, height = "default" } }
layout_pages = 1
home.page = 1
home.editing = false
can_fit = true
last_add = nil
home:enterEdit()
Assert.is_true(home.editing)
Assert.eq(last_strip.center, "title")
Assert.eq(last_strip.actions[1].text, "添加")
Assert.eq(last_strip.actions[2].text, "完成")
last_strip.actions[1].on_tap()
Assert.eq(last_add.candidates[1].id, "weather")
last_add.on_pick("weather")
Assert.eq(placements[#placements].id, "weather")
Assert.eq(placements[#placements].page, 1)
Assert.eq(home.page, 1)

enabled = { "clock" }
placements = { { id = "clock", page = 1, order = 1, height = "default" } }
home.page = 1
can_fit = false
last_add = nil
home:updateView()
Assert.eq(last_strip.actions[1].text, "添加")
last_strip.actions[1].on_tap()
Assert.eq(last_add.candidates[1].id, "weather")

-- 长按进编辑；暂停退出编辑并保存。
enabled = { "clock", "weather" }
placements = {
    { id = "clock", page = 1, order = 1, height = "default" },
    { id = "weather", page = 2, order = 1, height = "default" },
}
layout_pages = 2
home.page = 1
can_fit = true
home.editing = false
home:updateView()
Assert.is_false(home.editing)
home:enterEdit()
Assert.is_true(home.editing)
Assert.eq(last_strip.actions[1].text, "完成")
home:onPause()
Assert.is_false(home.editing)

home:onDestroy()
Assert.eq(home.lifecycle.state, "Destroy")
Assert.is_nil(home.desktop)
Assert.errors(function() home:onResume() end)

return true
