--[[-- 市场手动刷新：进度弹窗、连点保护、取消过期回调、失败保留缓存。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["json"] = function() return require("support.json_stub") end
package.preload["ffi/util"] = function()
    return { template = function(s, a, b, c)
        return (s:gsub("%%1", a or ""):gsub("%%2", b or ""):gsub("%%3", c or ""))
    end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local shown = {}
local function dialogModule()
    return {
        new = function(_, opts)
            function opts:show() shown[#shown + 1] = self end
            return opts
        end,
    }
end
package.preload["ui.themes.widgets.confirm"] = dialogModule
package.preload["ui.themes.widgets.toast"] = dialogModule
package.preload["ui.themes.widgets.progress_dialog"] = function()
    return {
        new = function(_, opts)
            opts.updates = {}
            function opts:show() shown[#shown + 1] = self; return self end
            function opts:showWhile(fn, ...) self:show(); return fn(...) end
            function opts:update(text, done, total)
                self.updates[#self.updates + 1] = { text = text, done = done, total = total }
            end
            function opts:close()
                if self._closed then return end
                self._closed = true
                if self.close_callback then self.close_callback() end
            end
            return opts
        end,
    }
end
package.preload["http.request"] = function()
    return { get = function() error("refresh 测试不得请求网络") end }
end

local Page = require("features.marketplace.page")
local Catalog = require("features.marketplace.catalog")
local Client = require("features.marketplace.client")

local desktop = { settings_overlay = { updateView = function() end } }

local function reset()
    Catalog.clear()
    shown = {}
end

-- 成功刷新：进度窗出现 → 更新进度 → 关闭 → 成功提示
reset()
Client.listCategories = function(cb)
    cb({ { code = "reader", name = "阅读增强" } }, nil)
    return { cancel = function() end }
end
Client.listPlugins = function(cb, progress)
    if progress then progress(1, 2) end
    if progress then progress(2, 2) end
    cb({
        { uid = "github:Acme/a", title = "A", repo = "a" },
        { uid = "github:Acme/b", title = "B", repo = "b" },
    }, nil)
    return { cancel = function() end }
end
Page.refresh(desktop)
Assert.eq(shown[1].title, "正在刷新")
Assert.is_true(shown[1]._closed)
Assert.eq(#shown[1].updates, 2)
Assert.eq(shown[1].updates[2].done, 2)
Assert.eq(shown[1].updates[2].total, 2)
Assert.eq(shown[2].text, "插件列表已更新。")
Assert.eq(#Catalog.plugins(), 2)

-- 刷新失败：提示错误且保留原有缓存
shown = {}
Client.listPlugins = function(cb)
    cb(nil, "network")
    return { cancel = function() end }
end
Page.refresh(desktop)
Assert.is_true(shown[1]._closed)
Assert.is_true(shown[2].text:find("网络请求失败", 1, true) ~= nil)
Assert.eq(#Catalog.plugins(), 2)

-- 连点不会启动第二次刷新
reset()
local pending
Client.listCategories = function(cb) cb({}, nil) return { cancel = function() end } end
Client.listPlugins = function(cb)
    pending = cb
    return { cancel = function() end }
end
Page.refresh(desktop)
Assert.is_true(Catalog.isRefreshing())
local first_n = #shown
Page.refresh(desktop)
Assert.eq(#shown, first_n + 1)
Assert.eq(shown[#shown].text, "正在刷新，请稍候。")
pending({}, nil)
Assert.is_false(Catalog.isRefreshing())

-- 取消后过期回调不得更新已关窗或写回缓存
reset()
pending = nil
Client.listPlugins = function(cb)
    pending = cb
    return { cancel = function() end }
end
Page.refresh(desktop)
local dialog = shown[1]
dialog:close()
dialog.on_cancel()
local after_cancel = #shown
local updates = #dialog.updates
pending({ { uid = "github:Acme/late", title = "Late", repo = "late" } }, nil)
Assert.eq(#dialog.updates, updates)
Assert.eq(#shown, after_cancel)
Assert.eq(#Catalog.plugins(), 0)

-- 6 小时周期延迟后台自动刷新
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, delay, fn)
        scheduled[#scheduled + 1] = { delay = delay, fn = fn, cancelled = false }
    end,
    unschedule = function(_, fn)
        for _idx, item in ipairs(scheduled) do
            if item.fn == fn then item.cancelled = true end
        end
    end,
}
package.loaded["ui.guard"] = {
    wrap = function(_label, fn) return fn end,
}
local net_connected = true
package.loaded["ui/network/manager"] = {
    isConnected = function() return net_connected end,
}
local Marketplace = require("features.marketplace")

-- 1. 未满 6 小时不安排刷新
reset()
Catalog.saveCache({
    updated_at = os.time(),
    categories = {},
    plugins = { { uid = "github:Acme/fresh", title = "Fresh", repo = "fresh" } },
})
scheduled = {}
Marketplace.scheduleAutoRefresh(desktop)
Assert.eq(#scheduled, 0, "6 小时内已刷新过时不应再安排后台刷新")

-- 2. 满 6 小时安排延迟刷新；重复激活不重复排队；离线时静默跳过
Catalog.saveCache({
    updated_at = os.time() - Catalog.AUTO_REFRESH_INTERVAL - 10,
    categories = {},
    plugins = { { uid = "github:Acme/old", title = "Old", repo = "old" } },
})
local bg_calls = 0
Client.listCategories = function(cb) cb({}, nil) return { cancel = function() end } end
Client.listPlugins = function(cb)
    bg_calls = bg_calls + 1
    cb({ { uid = "github:Acme/bg", title = "BG", repo = "bg" } }, nil)
    return { cancel = function() end }
end
net_connected = false
Marketplace.scheduleAutoRefresh(desktop)
Marketplace.scheduleAutoRefresh(desktop)
Assert.eq(#scheduled, 1)
Assert.eq(scheduled[1].delay, Marketplace.AUTO_REFRESH_DELAY)
scheduled[1].fn()
Assert.eq(bg_calls, 0, "离线时后台刷新应静默跳过")

-- 3. 联网时到点静默刷新，更新库并重绘已打开的市场叠层
net_connected = true
local redrawn = 0
local open_desk = {
    settings_overlay = {
        spec = { id = "feature:marketplace:marketplace" },
        updateView = function() redrawn = redrawn + 1 end,
    },
}
scheduled = {}
Marketplace.scheduleAutoRefresh(open_desk)
Assert.eq(#scheduled, 1)
scheduled[1].fn()
Assert.eq(bg_calls, 1)
Assert.eq(Catalog.get("github:Acme/bg").title, "BG")
Assert.eq(redrawn, 1)

-- 4. 后台静默刷新失败不污染 lastError
Catalog.saveCache({
    updated_at = os.time() - Catalog.AUTO_REFRESH_INTERVAL - 10,
    categories = {},
    plugins = { { uid = "github:Acme/keep", title = "Keep", repo = "keep" } },
})
Client.listPlugins = function(cb)
    cb(nil, "network")
    return { cancel = function() end }
end
scheduled = {}
Marketplace.scheduleAutoRefresh(open_desk)
scheduled[1].fn()
Assert.is_nil(Catalog.lastError(), "后台静默刷新失败不应污染界面错误态")
Assert.eq(Catalog.count(), 1)

-- 5. 后台静默刷新在途时，用户手动点刷新可直接接管并弹进度窗
local bg_cancelled = false
Client.listPlugins = function(_cb)
    return { cancel = function() bg_cancelled = true end }
end
Catalog.refresh(nil, { silent = true })
Assert.is_true(Catalog.isRefreshing())
Assert.is_false(Catalog.isManualRefreshing())
shown = {}
Client.listPlugins = function(cb)
    cb({ { uid = "github:Acme/manual", title = "Manual", repo = "manual" } }, nil)
    return { cancel = function() end }
end
Page.refresh(desktop)
Assert.is_true(bg_cancelled, "手动刷新应接管取消后台静默刷新")
Assert.eq(shown[1].title, "正在刷新")
Assert.eq(Catalog.get("github:Acme/manual").title, "Manual")

-- 6. onExit 取消未触发的自动刷新定时器
Catalog.saveCache({ updated_at = 1, categories = {}, plugins = {} })
scheduled = {}
Marketplace.scheduleAutoRefresh(desktop)
Assert.eq(#scheduled, 1)
Marketplace.onExit()
Assert.is_true(scheduled[1].cancelled)

Catalog.clear()
return true
