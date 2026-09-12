--[[--
首页新闻 / 历史：各组件自己 Myrl:fetch，Resume 拉网刷新。

@module tests.ui.desktop.home.feed_spec
--]]

local Assert = require("support.assert")
local paints = 0
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function() paints = paints + 1 end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return { template = function(s, value) return (s:gsub("%%1", tostring(value))) end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() end,
        muted = function() return 1 end,
        dim = function() return 2 end,
    }
end
local function containerStub()
    return { new = function(_, opts)
        opts.getSize = function(self) return self.dimen or { w = self.width or 0, h = self.height or 0 } end
        return opts
    end }
end
package.preload["ui/widget/container/centercontainer"] = containerStub
package.preload["ui/widget/container/framecontainer"] = containerStub
package.preload["ui/widget/container/leftcontainer"] = containerStub
package.preload["ui/widget/container/rightcontainer"] = containerStub
package.preload["ui/widget/verticalgroup"] = containerStub
package.preload["ui/widget/verticalspan"] = containerStub
package.preload["ui/widget/horizontalgroup"] = containerStub
package.preload["ui/widget/horizontalspan"] = containerStub

local texts = {}
package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, opts)
            local widget = { text = opts.text }
            function widget:setText(text) self.text = text end
            function widget:getSize() return { w = 80, h = 16 } end
            texts[#texts + 1] = widget
            return widget
        end,
    }
end

local fetch_payload
package.preload["online.myrl"] = function()
    return {
        fetch = function(_, _, cb)
            cb(fetch_payload or {})
            return { cancel = function() end }
        end,
    }
end

local ctx = { desktop = {} }
local opts = { width = 320, height = 100, y = 20 }

do -- 新闻 / 历史自己拉 myrl，空态一行
    for _, name in ipairs({ "news", "history" }) do
        texts, paints = {}, 0
        package.loaded["ui.desktop.home.views." .. name] = nil
        local Comp = require("ui.desktop.home.views." .. name)
        local comp = Comp:new()
        comp.lifecycle.state = "Resume"
        if name == "news" then
            fetch_payload = { news = { "冷空气", "上海生娃" } }
            comp.data = { "冷空气", "上海生娃" }
        else
            fetch_payload = { history = { { year = "1991", title = "苏联解体" } } }
            comp.data = { { year = "1991", title = "苏联解体" } }
        end
        comp:build(ctx, opts)
        local joined = {}
        for i, widget in ipairs(texts) do joined[i] = widget.text end
        if name == "news" then
            Assert.is_true(table.concat(joined, "\n"):find("01", 1, true) ~= nil)
            Assert.is_true(table.concat(joined, "\n"):find("冷空气", 1, true) ~= nil)
            fetch_payload = { news = { "新标题" } }
        else
            Assert.is_true(table.concat(joined, "\n"):find("1991", 1, true) ~= nil)
            Assert.is_true(table.concat(joined, "\n"):find("苏联解体", 1, true) ~= nil)
            fetch_payload = { history = { { year = "1976", title = "毛泽东逝世" } } }
        end
        local before = paints
        comp:onResume()
        Assert.is_true(paints > before)
        if name == "news" then
            Assert.eq(comp.items[1].text, "新标题")
        else
            Assert.eq(comp.marks[1].text, "1976")
            Assert.eq(comp.items[1].text, "毛泽东逝世")
        end
        comp.data = {}
        comp:updateView()
        Assert.eq(comp.items[1].text, "--")
        if name == "history" then
            Assert.eq(comp.marks[1].text, "")
        end
        comp:onDestroy()
    end
end

return true
