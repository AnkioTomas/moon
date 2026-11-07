--[[--
扫码预览不缓存；官方授权重取正文、会话隔离、刷新和关闭取消。

@module tests.source.tadu.reading_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Themed = require("support.theme_stubs")
Themed.install()
package.loaded["json"] = JSON
local cfg, requests, timers = {}, {}, {}
local gated, delayed, malformed = true, false, false
---@type boolean|string
local font = false
local status, create_status = 0, 200
local grant_clears = true
local font_wait, font_callback, font_cancelled
package.loaded["source.tadu.font"] = {
    restoreAsync = function(_html, bytes, cb)
        Assert.eq(bytes, "font fixture")
        if font_wait then font_callback = cb else cb("<p>字体正文</p>") end
        return { cancel = function() font_cancelled = true end }
    end,
}
local calls, result, reason, saves, result_style = 0, nil, nil, 0, nil
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() saves = saves + 1 end,
}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_self, _seconds, fn) timers[#timers + 1] = fn end,
    unschedule = function(_self, fn)
        for i = #timers, 1, -1 do if timers[i] == fn then table.remove(timers, i) end end
    end,
}
local valid_image = true
package.loaded["ui/renderimage"] = {
    renderImageData = function(_self, raw)
        Assert.eq(raw, "png")
        return valid_image and {} or nil
    end,
}
local page = '<input id="bookPartResourceUrl" value="/getPartContentByCodeTable/9/96">'
local gate = '<div class="appQrCode" data-url="/qrcode/invoke" data-status="/qrcode/check">'
package.loaded["http.request"] = {
    headerAll = function(res) return res and res.cookies or {} end,
    get = function(url, options, cb)
        local request = { url = url, options = options, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        if url:find("/book/", 1, true) then
            cb(malformed and "<html>error</html>" or page .. (gated and gate or ""))
        elseif url:find("/getPartContentByCodeTable/", 1, true) then
            cb(JSON.encode({ status = 200, data = { content = "<p>完整正文</p>",
                url = type(font) == "string" and font or font and "font.woff" or nil } }))
        elseif url:find("/font/chapter.ttf", 1, true) then
            cb("font fixture")
        elseif url:find("/qrcode/invoke", 1, true) then
            cb(JSON.encode({ status = create_status, data = {
                qid = "test-id", token = "test-ticket", qrcode = "data:image/png;base64,cG5n",
            } }), nil, { cookies = { "scan=pending; Path=/; HttpOnly" } })
        elseif not delayed then
            if status == 200 and grant_clears then gated = false end
            cb(JSON.encode({ status = status }), nil, status == 200 and { cookies = { "scan=approved; Path=/" } } or nil)
        end
        return handle
    end,
}
local Mapper = require("source.tadu.mapper")
local Client = require("source.tadu.client")
Assert.is_true(Mapper.reading(page .. gate, "9").gated)
Assert.is_false(Mapper.reading(page .. "<!--" .. gate .. "-->", "9").gated)
Assert.is_nil(Mapper.reading(page, "8"))
Assert.is_nil(Mapper.reading(page .. gate:gsub("/qrcode/invoke", "//evil.test"), "9"))

local function callback(html, err, style)
    calls, result, reason, result_style = calls + 1, html, err, style
end
local function open(interactive)
    calls, result, reason, result_style = 0, nil, nil, nil
    return Client.contentAsync("9", "105", callback, "1050", interactive)
end

open(false)
Assert.is_nil(result)
Assert.eq(reason, "塔读此章节需要 App 扫码授权，请先打开章节扫码阅读")
Assert.len(requests, 1, "限制页不能下载或缓存预览")
Assert.len(Themed.all("qr"), 0, "后台缓存不能弹扫码窗口")
Assert.eq(saves, 0)

local handle = open(true)
local dialog = Themed.last("qr")
Assert.eq(dialog.title, "塔读 App 扫码阅读")
Assert.is_true(dialog.image ~= nil)
Assert.is_nil(dialog.text, "官方二维码不能把图片地址当二维码内容")
Assert.eq(calls, 0)
Assert.len(timers, 1)
Assert.matches(requests[#requests].options.headers.Cookie, "scan=pending")
Assert.eq(requests[#requests].options.cache_ttl, 0)
handle.cancel()
Assert.is_true(dialog.closed)
Assert.len(timers, 0)
Assert.eq(calls, 0, "外部取消不重新调用开章回调")
Assert.is_nil(cfg.read_cookie, "未授权不保存候选Cookie")

status = 1
handle = open(true)
Assert.eq(calls, 0, "status=1仍等待，不能当确认成功")
Themed.last("qr").actions[1].callback()
Assert.eq(calls, 1)
Assert.eq(reason, "已取消")
Assert.len(timers, 0)

delayed = true
handle = open(true)
local old = requests[#requests]
Themed.last("qr").actions[2].callback()
Assert.is_true(old.cancelled)
old.cb(JSON.encode({ status = 200 }))
Assert.eq(calls, 0, "刷新后旧票据不能授权下一轮")
local current = requests[#requests]
handle.cancel()
Assert.is_true(current.cancelled, "同步创建后的取消必须终止当前轮询")
current.cb(JSON.encode({ status = 200 }))
Assert.eq(calls, 0)

delayed, status = false, 200
cfg.cookie, cfg.logged_in = "account=old", true
open(true)
Assert.eq(result, "<p>完整正文</p>")
Assert.eq(calls, 1, "同步全流程只交付一次")
Assert.eq(cfg.cookie, "account=old", "阅读授权不能覆盖书架登录")
Assert.matches(cfg.read_cookie, "scan=approved")
Assert.eq(cfg.read_cookie_for, "account=old")
Assert.matches(requests[#requests].url, "/9/96", "正文序号采用阅读页，而不是旧目录位置")
Assert.matches(requests[#requests].options.headers.Cookie, "scan=approved")
Assert.eq(saves, 1)
open(false)
Assert.eq(result, "<p>完整正文</p>")
Assert.eq(saves, 1, "未变化的Cookie不重复落盘")
cfg.cookie = "account=new"
open(false)
Assert.is_true(not requests[#requests].options.headers.Cookie:find("scan=approved", 1, true),
    "不同登录不能复用旧账号阅读授权")

gated, delayed = true, true
handle = open(true)
local changed = requests[#requests]
cfg.cookie = "account=another"
changed.cb(JSON.encode({ status = 200 }))
Assert.eq(calls, 0)
Assert.eq(Themed.last("confirm").text, "塔读登录已改变，请重试")
Themed.last("confirm").cancel_callback()
Assert.eq(calls, 1)
Assert.eq(reason, "塔读登录已改变，请重试")

delayed, status, grant_clears = false, 200, false
local saved_cookie = cfg.read_cookie
open(true)
Assert.is_nil(result, "轮询成功仍须回读权限，限制页不能缓存")
Assert.eq(reason, "塔读此章节需要 App 扫码授权，请先打开章节扫码阅读")
Assert.eq(cfg.read_cookie, saved_cookie)
grant_clears = true

gated, delayed, font = false, false, true
open(false)
Assert.is_nil(result)
Assert.eq(reason, "塔读章节字体还原失败，请重试")
font = "https://www.tadu.com/font/chapter.ttf"
open(false)
Assert.eq(result, "<p>字体正文</p>", "通过权限后必须下载字体并交付正文")
Assert.is_nil(result_style, "解码后的正文不能依赖字体样式")
Assert.matches(requests[#requests].url, "/font/chapter.ttf")
gated = true
open(true)
Assert.eq(result, "<p>字体正文</p>", "扫码授权回读也必须还原正文")
Assert.is_nil(result_style)
font_wait = true
handle = open(true)
handle.cancel()
Assert.is_true(font_cancelled, "字体阶段取消必须调用 Job:cancel")
font_callback("<p>迟到正文</p>")
Assert.eq(calls, 0)
open(false)
cfg.cookie = "account=changed-during-font"
font_callback("<p>旧账号正文</p>")
Assert.eq(reason, "塔读登录已改变，请重试")
font_wait = false
malformed = true
open(false)
Assert.eq(reason, "塔读阅读页无法识别")
malformed, gated, font, status = false, true, false, 402
open(true)
Assert.eq(Themed.last("confirm").text, "二维码已过期")
Assert.eq(calls, 0)
Themed.last("confirm").cancel_callback()
Assert.eq(calls, 1)
create_status = 500
open(true)
Assert.eq(Themed.last("confirm").text, "获取二维码失败")
handle = open(true)
handle.cancel()
Assert.eq(calls, 0)

create_status, valid_image = 200, false
open(true)
Assert.eq(Themed.last("confirm").text, "获取二维码失败")
Themed.last("confirm").cancel_callback()
Assert.eq(calls, 1)

valid_image, delayed = true, true
handle = open(true)
requests[#requests].cb(nil, "network failure")
Assert.eq(Themed.last("confirm").text, "network failure", "网络失败不能冒充二维码过期")
Themed.last("confirm").cancel_callback()
Assert.eq(calls, 1)

delayed, status = false, 0
local time = os.time
open(true)
local waiting = table.remove(timers)
os.time = function() return time() + 301 end
waiting()
os.time = time
Assert.eq(Themed.last("confirm").text, "二维码已过期", "官网一直等待也必须有本地截止时间")
Themed.last("confirm").cancel_callback()
Assert.eq(calls, 1)
