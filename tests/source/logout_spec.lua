--[[--
退出登录：先删凭证并丢掉源实例，再清本地记录。清库失败也保持登出。

@module tests.source.logout_spec
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")

Themed.install()
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local forgotten, forget_ok = {}, true
local order = {}
package.preload["book.store"] = function()
    return {
        forgetSource = function(id)
            order[#order + 1] = "forget"
            forgotten[#forgotten + 1] = id
            return forget_ok
        end,
    }
end

local cancelled = {}
package.preload["workers.tasks"] = function()
    return {
        cancelPrefixed = function(prefix)
            if #order == 0 then order[#order + 1] = "abort" end
            cancelled[#cancelled + 1] = prefix
        end,
        get = function() end,
    }
end

local reloads = 0
package.preload["source.registry"] = function()
    return {
        invalidate = function() order[#order + 1] = "invalidate" end,
        reload = function() reloads = reloads + 1 end,
    }
end

local Logout = require("source.logout")
local cleared = 0
local function clear()
    order[#order + 1] = "clear"
    cleared = cleared + 1
end

local row = Logout.row("wechat", "确定退出微信读书账号？", clear)(300)
Assert.eq(row.title, "退出登录")
row.callback()
Assert.eq(cleared, 0, "未确认不退出")
local confirm = Themed.last("confirm")
Assert.is_true(confirm.text:find("确定退出微信读书账号？", 1, true) ~= nil)
Assert.is_true(confirm.text:find("书架、阅读进度、笔记和缓存会一并清除", 1, true) ~= nil)

confirm.ok_callback()
Assert.eq(table.concat(order, ","), "abort,clear,invalidate,forget", "凭证还在时不许清书架")
Assert.eq(forgotten[1], "wechat")
Assert.eq(cleared, 1)
Assert.eq(reloads, 1)
Assert.eq(Themed.last("toast").text, "已退出登录")
Assert.eq(cancelled[1], "dirty\0wechat")
Assert.eq(cancelled[2], "books\0wechat")

forget_ok = false
order = {}
confirm.ok_callback()
Assert.eq(table.concat(order, ","), "abort,clear,invalidate,forget")
Assert.eq(cleared, 2, "清库失败也已经登出")
Assert.eq(reloads, 2)
Assert.eq(Themed.last("toast").text, "清除本地记录失败")

-- 换库身份：不改凭证回调，整源 forget + 必定 reload
forget_ok, order, reloads, forgotten = true, {}, 0, {}
Assert.is_true(Logout.replaceLibrary("kavita"))
Assert.eq(table.concat(order, ","), "abort,invalidate,forget")
Assert.eq(forgotten[1], "kavita")
Assert.eq(reloads, 1)

-- 换 WebDAV：走 forgetWebdav，不动整源 forgetSource
local webdav = 0
package.preload["book.store"] = function()
    return {
        forgetSource = function(id)
            order[#order + 1] = "forget"
            forgotten[#forgotten + 1] = id
            return forget_ok
        end,
        forgetWebdav = function()
            order[#order + 1] = "forgetWebdav"
            webdav = webdav + 1
            return true
        end,
    }
end
package.loaded["book.store"] = nil
package.loaded["source.logout"] = nil
Logout = require("source.logout")
order, reloads = {}, 0
Assert.is_true(Logout.replaceWebdav())
Assert.eq(table.concat(order, ","), "abort,invalidate,forgetWebdav")
Assert.eq(webdav, 1)
Assert.eq(reloads, 1)

package.preload["ui.themes.widgets.row"] = nil

return true
