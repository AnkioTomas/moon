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

-- 换库身份：清理成功才提交新配置并重载。
forget_ok, order, reloads, forgotten = true, {}, 0, {}
local commits = 0
local function commit()
    commits = commits + 1
    order[#order + 1] = "commit"
end
Assert.is_true(Logout.replaceLibrary("kavita", commit))
Assert.eq(table.concat(order, ","), "abort,forget,invalidate,commit")
Assert.eq(forgotten[1], "kavita")
Assert.eq(reloads, 1)
Assert.eq(commits, 1)

forget_ok, order, reloads, commits = false, {}, 0, 0
Assert.is_false(Logout.replaceLibrary("kavita", commit))
Assert.eq(table.concat(order, ","), "abort,forget")
Assert.eq(commits, 0, "清库失败不得提交新凭证")
Assert.eq(reloads, 0, "清库失败不得激活新源")

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
            return forget_ok
        end,
    }
end
package.loaded["book.store"] = nil
package.loaded["source.logout"] = nil
Logout = require("source.logout")
forget_ok, order, reloads, commits = true, {}, 0, 0
Assert.is_true(Logout.replaceWebdav(commit))
Assert.eq(table.concat(order, ","), "abort,forgetWebdav,invalidate,commit")
Assert.eq(webdav, 1)
Assert.eq(reloads, 1)
Assert.eq(commits, 1)

forget_ok, order, reloads, commits = false, {}, 0, 0
Assert.is_false(Logout.replaceWebdav(commit))
Assert.eq(table.concat(order, ","), "abort,forgetWebdav")
Assert.eq(commits, 0)
Assert.eq(reloads, 0)

-- 实际账号设置行必须在清理前保留旧配置，而不是只补一条错误提示。
do
    local configs = {
        moon = { base_url = "https://old.test", token = "old-token" },
        bookorbit = { server_url = "https://old.test", username = "old", userkey = "key" },
    }
    local saved = 0
    package.loaded["utils.settings"] = {
        getSource = function(id) return configs[id] end,
        saveSource = function(id, cfg) configs[id] = cfg; saved = saved + 1 end,
    }
    for _idx, id in ipairs({ "moon", "bookorbit" }) do
        local key = id == "moon" and "base_url" or "server_url"
        local Setting = require("source." .. id .. ".setting")
        Setting.rows()[1](300).callback()
        Themed.last("input").callback("https://new.test")
        Assert.eq(configs[id][key], "https://old.test")
        Assert.eq(saved, 0)
        Assert.eq(Themed.last("toast").text, "清除本地记录失败")
        forget_ok = true
        Setting.rows()[1](300).callback()
        Themed.last("input").callback("https://new.test")
        Assert.eq(configs[id][key], "https://new.test")
        saved, forget_ok = 0, false
    end
end

package.preload["ui.themes.widgets.row"] = nil

return true
