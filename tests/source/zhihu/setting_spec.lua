--[[--
知乎账号入口、Cookie 授权与登录后重新检查匿名目录里的付费章。

@module tests.source.zhihu.setting_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local Settings = require("utils.settings")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
package.loaded["ui/network/manager"] = { runWhenConnected = function(_self, fn) fn() end }

local cfg = Settings.getSource("zhihu")
cfg.cookie = nil
cfg.show_paragraph_reviews = nil
local checked, allow, reloads = {}, false, 0
package.loaded["source.registry"] = {
    reload = function() reloads = reloads + 1 end,
    invalidate = function() end,
}
local html, content_error, downloads, content_id = "<p>已购正文</p>", nil, 0, nil
package.loaded["source.zhihu.client"] = {
    cookie = function() return cfg.cookie end,
    loginCheckAsync = function(cookie, cb)
        checked[#checked + 1] = cookie
        cb(allow, not allow and "rejected" or nil)
    end,
    contentAsync = function(id, cb)
        downloads = downloads + 1
        content_id = id
        cb(html, content_error)
        return { cancel = function() end }
    end,
}
local scanned
package.loaded["source.zhihu.qrlogin"] = {
    new = function(_self, on_ok)
        return {
            start = function() scanned = on_ok end,
            cancel = function() scanned = nil end,
        }
    end,
}
local Setting = require("source.zhihu.setting")
Assert.eq(select(2, Setting.rowStatus()), false)
local row = Setting.rows()[1](400)
Assert.eq(row.subtitle, "用知乎 App 扫一扫")
local review_row = Setting.rows()[3](400)
Assert.eq(review_row.title, "显示段评")
Assert.is_false(review_row.status_on)
review_row.callback()
Assert.is_true(cfg.show_paragraph_reviews)
Assert.is_true(Setting.rows()[3](400).status_on)
Setting.rows()[3](400).callback()
Assert.is_false(cfg.show_paragraph_reviews)
row.callback()
Assert.eq(type(scanned), "function")
Assert.is_nil(Themed.last("input"), "账号入口直接扫码，不再弹手机号表单")
Setting.rows()[2](400).callback()
Assert.eq(Themed.last("input").title, "知乎登录 Cookie")
Themed.last("input").callback("  ")
Assert.eq(Themed.last("toast").text, "没有读到 Cookie")
Assert.len(checked, 0)

local payload = { cookies = {
    { domain = ".zhihu.com", name = "z_c0", value = "fixture" },
    { domain = "zhihu.com.evil.test", name = "other", value = "excluded" },
} }
local accepted, reason
Setting.browser.apply(payload, function(ok, err) accepted, reason = ok, err end)
Assert.is_false(accepted)
Assert.eq(reason, "rejected")
Assert.is_nil(cfg.cookie)
Assert.eq(reloads, 0)
allow = true
Setting.browser.apply(payload, function(ok, err) accepted, reason = ok, err end)
Assert.is_true(accepted)
Assert.is_nil(reason)
Assert.eq(cfg.cookie, "z_c0=fixture")
Assert.eq(checked[#checked], "z_c0=fixture")
Assert.eq(reloads, 1)
Assert.is_true(Setting.browser.isAuthorized())
Assert.eq(select(2, Setting.rowStatus()), true)
Assert.len(Setting.rows(), 4)

allow = false
Setting.browser.apply(payload, function(ok) accepted = ok end)
Assert.is_false(accepted)
Assert.eq(cfg.cookie, "z_c0=fixture", "重新授权失败保留已有登录")
Assert.eq(reloads, 1)

local open_fetch, cache_fetch, paid
package.loaded["source.chapter"] = {
    openAsync = function(_source, _identity, _book, _opts, ops) open_fetch = ops.fetchContent end,
    cacheAllAsync = function(_source, _identity, fetch) cache_fetch = fetch end,
}
package.loaded["source.zhihu.story"] = {
    openAsync = function(_source, _identity, _opts, ops) open_fetch = ops.fetchContent end,
}
package.loaded["source.toc"] = {
    markPaid = function(id, stable_id, uid, value)
        Assert.eq(id, "zhihu")
        Assert.eq(stable_id, "1/2")
        Assert.eq(uid, "2")
        paid = value
    end,
}
local source = require("source.zhihu").new()
Assert.is_false(source:paragraphReviewsEnabled())
require("source.review_setting").set("zhihu", true)
Assert.is_true(source:paragraphReviewsEnabled(), "设置页和源实例读同一份开关")
require("source.review_setting").set("zhihu", false)
Assert.is_false(source:paragraphReviewsEnabled(), "开关就地生效，不必重建源实例")
local identity = { source_id = "zhihu", stable_id = "1/2" }
local chapter = { idx = 1, uid = "2", title = "第一节", vip = true }
source:openBookAsync(identity, { chapter_idx = 1 }, function() end)
local result, failure
open_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.eq(result.html, require("source.zhihu.content").prepare("<p>已购正文</p>"),
    "登录后不能被匿名目录里的 vip 标记挡住")
Assert.is_nil(result.temporary)
Assert.is_true(paid)
Assert.is_nil(failure)

html, content_error = nil, "本章未购买"
open_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.is_true(result.temporary)
Assert.is_nil(failure)
source:cacheAllChaptersAsync(identity, nil, function() end)
cache_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.is_nil(result)
Assert.eq(failure, "本章未购买", "后台缓存不能把购买提示存成正文")
content_error = "network down"
open_fetch(identity, chapter, function(value, err) result, failure = value, err end)
Assert.is_nil(result)
Assert.eq(failure, "network down")

html, content_error = "<p>长篇章节</p>", nil
open_fetch({ source_id = "zhihu", stable_id = "3" }, { idx = 1, uid = "4", title = "第一节" },
    function(value, err) result, failure = value, err end)
Assert.eq(content_id, "3/4", "长篇按当前章节请求正文，不把专栏 id 当作节 id")
Assert.eq(result.html, require("source.zhihu.content").prepare(html))
Assert.is_nil(failure)

local before = downloads
cfg.cookie = nil
open_fetch(identity, chapter, function(value) result = value end)
Assert.is_true(result.temporary)
Assert.eq(downloads, before, "匿名未购买章保持原来的立即提示")
scanned()
Assert.eq(Themed.last("toast").text, "登录成功")
Assert.eq(reloads, 2)
Setting.rows()[1](400).callback()
Assert.eq(type(scanned), "function")
scanned()
Assert.eq(Themed.last("toast").text, "登录成功")
Assert.eq(reloads, 3)
Settings.saveSource("zhihu")
