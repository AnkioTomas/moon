--[[--
fontpicker：无系统默认行；预览按页懒构建。

@module tests.ui.components.fontpicker_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local getface_n = 0
local image_n = 0
local captured_menu
local list_force

package.preload["ui/font"] = function()
    return {
        getFace = function(_, id)
            getface_n = getface_n + 1
            return { id = id }
        end,
    }
end

package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        fontSize = function(n) return n end,
        menuFontSize = function() return 22 end,
        iconSz = function() return 24 end,
    }
end

package.preload["ui.components.image"] = function()
    return {
        widget = function(o)
            image_n = image_n + 1
            return {
                _src = o.src,
                getSize = function() return { w = o.width, h = o.height } end,
            }
        end,
    }
end

package.preload["ui/widget/textwidget"] = function()
    local TextWidget = {}
    function TextWidget:new(o)
        o = o or {}
        o.getSize = function() return { w = 80, h = 20 } end
        return o
    end
    return TextWidget
end

package.preload["ui/widget/infomessage"] = function()
    local InfoMessage = {}
    function InfoMessage:new(o) return o or {} end
    return InfoMessage
end

package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return false end,
        runWhenOnline = function(_, cb) cb() end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        nextTick = function(_, cb)
            if type(cb) ~= "function" then cb = _ end
            if type(cb) == "function" then cb() end
        end,
        setDirty = function() end,
    }
end

package.preload["utils.font"] = function()
    local items = {}
    for i = 1, 40 do
        items[#items + 1] = {
            id = string.format("Font%02d.ttf", i),
            name = string.format("Font%02d", i),
            kind = "local",
        }
    end
    for i = 1, 20 do
        items[#items + 1] = {
            id = "wr" .. i,
            name = "Weread" .. i,
            kind = "weread",
            preview = "https://example.com/p" .. i .. ".svg",
            url = "https://example.com/f" .. i .. ".zip",
            zip_size = 1000,
        }
    end
    return {
        listAsync = function(force, cb)
            list_force = force
            return {
                cancel = function() end,
                _run = function() cb(items) end,
            }
        end,
        currentId = function() return "" end,
        isInstalled = function() return true end,
        set = function() return true end,
        ensureInstalledAsync = function(_, _, cb) cb(true) end,
    }
end

package.preload["ui.components.popup"] = function()
    return {
        list = function(opts)
            local item_table = {}
            for _, row in ipairs(opts.items or {}) do
                item_table[#item_table + 1] = { text = row.text }
            end
            captured_menu = {
                item_table = item_table,
                perpage = 10,
                page = 1,
                state_w = nil,
                updateItems = function(self)
                    self._updates = (self._updates or 0) + 1
                end,
            }
            return captured_menu
        end,
    }
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["ffi/util"] = function()
    return { template = function(s, a) return (s:gsub("%%1", tostring(a or ""))) end }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 1 }
end

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, n) return n end,
        },
    }
end

package.loaded["ui.components.fontpicker"] = nil
package.loaded["ui.components.popup"] = nil
package.loaded["ui.components.image"] = nil
package.loaded["ui.components.bookui"] = nil
package.loaded["utils.font"] = nil
package.loaded["ui/font"] = nil

-- listAsync 在 stub 里不自动跑 cb：包一层让 open 能同步拿到结果
local real_preload = package.preload["utils.font"]
package.preload["utils.font"] = function()
    local m = real_preload()
    local orig = m.listAsync
    m.listAsync = function(force, cb)
        local job = orig(force, cb)
        job._run()
        return job
    end
    return m
end

local FontPicker = require("ui.components.fontpicker")
FontPicker.open{ title = "字体" }

Assert.is_true(captured_menu ~= nil, "menu created")
Assert.eq(list_force, false, "cache-first listAsync(false)")
Assert.eq(#captured_menu.item_table, 60, "no system-default row")
-- 第 1 页 10 个 local → 10 次 getFace
Assert.is_true(getface_n <= 10, "lazy local preview, got " .. tostring(getface_n))
Assert.is_true(getface_n >= 1, "first page built some local previews")
Assert.eq(image_n, 0, "no weread image on page 1")

-- page 5 = indices 41..50 → weread
getface_n = 0
image_n = 0
captured_menu.page = 5
captured_menu:updateItems()
Assert.eq(getface_n, 0, "page 5 is weread-only")
Assert.is_true(image_n > 0 and image_n <= 10, "weread previews for visible page, got " .. tostring(image_n))

local images_before = image_n
captured_menu:updateItems()
Assert.eq(image_n, images_before, "preview cache per index")
