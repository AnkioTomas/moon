--[[--
View: skeleton identity, region ownership, cancellation and independent export.
@module tests.ui.view_spec
--]]
local Assert = require("support.assert")
local dirty = {}
local Geom = {}
Geom.__index = Geom
function Geom:new(rect) return setmetatable(rect, self) end
package.preload["ui/uimanager"] = function()
    return { setDirty = function(_, host, _, rect)
        Assert.eq(getmetatable(rect), Geom, "UIManager requires a Geom, not a plain rectangle")
        dirty[#dirty + 1] = { host = host, rect = rect }
    end }
end
package.preload["ui/geometry"] = function()
    return Geom
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self[1]:getSize() end
        opts.free = function(self) if self[1].free then self[1]:free() end end
        return opts
    end }
end
local View = require("ui.view")
local TestView = setmetatable({}, View)
TestView.__index = TestView
local builds, frees = 0, 0
function TestView:createWidget()
    builds = builds + 1
    return { getSize = function() return { w = self.width or 20, h = self.height or 30 } end,
        free = function() frees = frees + 1 end }
end
local view = TestView:new{ state = { query = "kept" } }
view:onCreate()
Assert.eq(view.state.query, "kept")
Assert.eq(view.lifecycle.state, "Create")
local root = view:build()
Assert.eq(view:build(), root)
Assert.eq(builds, 1)
local old_freed, new_freed = 0, 0
local old = { free = function() old_freed = old_freed + 1 end }
local next_widget = { free = function() new_freed = new_freed + 1 end }
local container = { old }
local region = { x = 10, y = 20, w = 90, h = 50 }
function container:resetLayout() region = { x = 10, y = 20, w = 40, h = 30 } end
view:registerRegion("body", container, 1, function() return region end)
view.host = {}
view:onResume()
view:replaceRegion("body", next_widget)
Assert.eq(old_freed, 1)
Assert.eq(container[1], next_widget)
Assert.eq(dirty[1].rect.w, 90, "erase the old larger rectangle")
Assert.eq(dirty[1].rect.h, 50)
view:replaceRegion("body", next_widget)
Assert.eq(new_freed, 0, "same identity must not be freed")
view:onPause()
view:dirty("body")
Assert.eq(#dirty, 1)
root:free()
Assert.eq(view.lifecycle.state, "Destroy")
Assert.eq(frees, 1)
view:onDestroy()
Assert.eq(frees, 1)
Assert.errors(function() view:build() end, "destroyed")

local requests = {}
function TestView:loadData(done)
    local request = { done = done, cancelled = false }
    requests[#requests + 1] = request
    return { cancel = function() request.cancelled = true end }
end
local first, second = TestView:new(), TestView:new()
local callbacks = 0
first:load(function() callbacks = callbacks + 1 end)
second:load(function() callbacks = callbacks + 1 end)
first:load(function() callbacks = callbacks + 1 end)
Assert.is_true(requests[1].cancelled)
requests[1].done("stale")
Assert.is_nil(first.data)
first:onPause()
Assert.is_true(requests[3].cancelled)
Assert.is_false(requests[2].cancelled)
requests[3].done("late")
Assert.eq(callbacks, 0)
requests[2].done("fresh")
Assert.eq(second.data, "fresh")
Assert.eq(callbacks, 1)
Assert.eq(#second.lifecycle.http, 0)

local pending_images, writes = {}, {}
package.preload["ui.components.image"] = function()
    return { await = function(widget, cb)
        local item = { widget = widget, cb = cb }
        pending_images[#pending_images + 1] = item
        return { cancel = function() item.cancelled = true end }
    end }
end
package.preload["ui.render"] = function()
    return {
        write = function(path, w, h, paint)
            writes[#writes + 1] = { path = path, w = w, h = h }
            paint({})
            return path ~= "failure", path == "failure" and "IO failure" or nil
        end,
        paintWidget = function(_, block, w, h)
            Assert.eq(block.widget:getSize().w, w)
            Assert.eq(block.widget:getSize().h, h)
        end,
    }
end
local resumes, exports = 0, {}
function TestView:onResume() resumes = resumes + 1 end
local function exported(ok, err, path) exports[#exports + 1] = { ok = ok, err = err, path = path } end
local before = frees
local one = TestView:renderToImage({ path = "one", width = 120, height = 200 }, exported)
local two = TestView:renderToImage({ path = "two", width = 240, height = 300 }, exported)
requests[4].done("one")
requests[5].done("two")
Assert.eq(#writes, 0, "must await images")
one:cancel()
Assert.is_true(pending_images[1].cancelled)
pending_images[1].cb()
Assert.eq(#writes, 0)
pending_images[2].cb()
Assert.eq(#writes, 1)
Assert.eq(writes[1].path, "two")
Assert.eq(writes[1].w, 240)
Assert.eq(#exports, 1)
Assert.is_true(exports[1].ok)
Assert.eq(exports[1].path, "two")
Assert.eq(frees, before + 2)
Assert.eq(resumes, 0, "export must not activate screen timers")
two:cancel()
pending_images[2].cb()
Assert.eq(#exports, 1)
Assert.eq(frees, before + 2)

TestView:renderToImage({ path = "failure", width = 120, height = 200 }, exported)
requests[6].done("data")
pending_images[3].cb()
Assert.is_false(exports[2].ok)
Assert.eq(exports[2].err, "IO failure")
Assert.is_nil(exports[2].path)
TestView:renderToImage({ path = "network-failure", width = 120, height = 200 }, exported)
requests[7].done(nil, "timeout")
Assert.eq(exports[3].err, "timeout")
Assert.eq(#writes, 2)
Assert.errors(function() TestView:renderToImage({ path = "bad", width = 0, height = 20 }, exported) end,
    "invalid image width")

local Static = setmetatable({}, View)
Static.__index = Static
function Static:createWidget() error("build failed") end
Static:renderToImage({ path = "bad", width = 20, height = 20 }, exported)
Assert.matches(exports[4].err, "build failed")
Assert.is_false(exports[4].ok)

-- Layout changes may hide an owned child without destroying its cached view.
local Parent = setmetatable({}, View)
Parent.__index = Parent
function Parent:createWidget()
    local content = { self.children[self.active]:build() }
    content.getSize = function() return { w = 20, h = 30 } end
    content.free = function(self)
        for _, child in ipairs(self) do child:free() end
    end
    return content
end
local parent = Parent:new{ active = "one" }
parent.children.one, parent.children.two = TestView:new(), TestView:new()
local parent_root = parent:build()
local parked = parent.children.one:build()
parent.active = "two"
parent:rebuild()
Assert.eq(parent:build(), parent_root)
Assert.eq(parent.children.one:build(), parked)
Assert.eq(parent.children.one.lifecycle.state, "new", "hidden child remains owned")
parent.active = "one"
parent:rebuild()
Assert.eq(parent.children.one:build(), parked)
local first_child, second_child = parent.children.one, parent.children.two
parent:onDestroy()
Assert.eq(first_child.lifecycle.state, "Destroy")
Assert.eq(second_child.lifecycle.state, "Destroy")
Assert.is_nil(parent.widget)

-- Native parents freeing a root must release the subtree even if a destroy hook fails.
local BrokenDestroy = setmetatable({}, TestView)
BrokenDestroy.__index = BrokenDestroy
function BrokenDestroy:onDestroy() error("cleanup failed") end
local broken = BrokenDestroy:new()
local broken_root = broken:build()
local before_cleanup = frees
Assert.errors(function() broken_root:free() end, "cleanup failed")
Assert.eq(frees, before_cleanup + 1)
broken_root:free()
Assert.eq(frees, before_cleanup + 1)

-- 原地刷新、静态/动态区域都必须交付独立的 Geom 快照。
local refresh_view = TestView:new{ host = {} }
local refresh_root = refresh_view:build()
refresh_root._view_x, refresh_root._view_y = 12, 34
refresh_view:onResume()
local start = #dirty
refresh_view:dirty("content")
Assert.eq(#dirty, start + 1)
Assert.eq(dirty[#dirty].rect.x, 12)
Assert.eq(dirty[#dirty].rect.y, 34)
local plain = { x = 5, y = 6, w = 7, h = 8 }
refresh_view:registerRegion("static", {}, 1, plain)
refresh_view:dirty("static")
local queued = dirty[#dirty].rect
Assert.eq(queued.w, 7)
Assert.is_nil(getmetatable(plain), "registering a region must not mutate the caller's table")
plain.w = 50
Assert.eq(queued.w, 7, "queued refresh must not follow later layout mutations")
refresh_view:registerRegion("dynamic", {}, 1, function() return plain end)
refresh_view:dirty("dynamic")
Assert.eq(dirty[#dirty].rect.w, 50)
refresh_view:onPause()
local paused = #dirty
refresh_view:dirty("content")
Assert.eq(#dirty, paused)
refresh_view:onDestroy()

-- 有本机 KOReader 源码时，执行真实的刷新矩形碰撞和合并方法。
local geometry_loader = loadfile(BOOK_TEST_ROOT .. "/koreader/frontend/ui/geometry.lua")
if geometry_loader then
    package.preload["optmath"] = function() return {} end -- 本测试不使用取整辅助函数。
    Geom = geometry_loader()
    package.loaded["ui/geometry"] = Geom
    local queued = Geom:new{ x = 0, y = 0, w = 20, h = 20 }
    local calls = 0
    package.loaded["ui/uimanager"] = {
        setDirty = function(_, _, _, rect)
            -- 与 UIManager:_refresh 相同：已有刷新时求交，再合并。
            Assert.is_true(rect:openIntersectWith(queued))
            queued = rect:combine(queued)
            calls = calls + 1
        end,
    }
    local live = TestView:new{ host = {} }
    local live_root = live:build()
    live_root._view_x, live_root._view_y = 10, 10
    live:onResume()
    live:dirty("content")
    Assert.eq(calls, 1)
    Assert.eq(queued.x, 0)
    Assert.eq(queued.y, 0)
    Assert.eq(queued.w, 30)
    Assert.eq(queued.h, 40)
    live:rebuild()
    Assert.eq(calls, 2)
    live:onPause()
    live:dirty("content")
    Assert.eq(calls, 2)
    live:onDestroy()
end
