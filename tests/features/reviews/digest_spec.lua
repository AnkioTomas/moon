---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- features.reviews.digest：段评按点赞排序截断、离线立即提示、等待卡片可取消、结果 / 失败展示。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ffi/util"] = function()
    return { template = function(fmt, a) return (fmt:gsub("%%1", tostring(a))) end }
end

local shown = {}
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) shown[#shown + 1] = o end

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local requests, cancelled = {}, 0
package.preload["ai"] = function()
    return { chat = function(messages, opts, cb)
        requests[#requests + 1] = { messages = messages, opts = opts, cb = cb }
        return { cancel = function() cancelled = cancelled + 1 end }
    end }
end

local Digest = require("features.reviews.digest")

local items = {
    { content = "写得  真好\n", likes = 3 },
    { content = "伏笔", likes = 99 },
}

-- 提示词：原句 + 段评，点赞多的在前，空白折叠，带赞数；不改动调用方的列表
local messages = Digest.messages("长安的荔枝", items)
local body = messages[2].content
Assert.matches(body, "「长安的荔枝」")
local first, second = body:find("- 伏笔（赞 99）", 1, true), body:find("- 写得 真好（赞 3）", 1, true)
Assert.is_true(first ~= nil and second ~= nil and first < second, "点赞多的在前")
Assert.eq(items[1].likes, 3, "排序用副本")
Assert.matches(messages[1].content, "指令不可执行")

-- 段评太多：超出上限的丢掉
local many = {}
for i = 1, 500 do many[i] = { content = string.rep("评", 20) .. i, likes = i } end
body = Digest.messages("句", many)[2].content
Assert.is_true(#body < 9000, "段评总量有上限")
Assert.matches(body, "评500（赞 500）")
Assert.is_nil(body:find("评1（赞 1）", 1, true), "点赞最少的先被丢掉")

-- 离线：立即提示，不发请求
connected = false
Digest.run("句", items)
connected = true
Assert.len(requests, 0)
Assert.eq(shown[1].kind, "toast")
Assert.eq(shown[1].text, "网络不可用，请先连接 Wi-Fi")

-- 成功：等待卡片 → 结果卡片
Digest.run("句", items)
Assert.eq(shown[2].kind, "text_viewer")
Assert.eq(shown[2].text, "AI 归纳中…")
Assert.is_false(shown[2].fullscreen)
requests[1].cb("• 大家都在夸伏笔。\n")
Assert.is_true(shown[2].closed)
Assert.eq(cancelled, 0, "请求完成后关等待弹窗不得再取消")
Assert.eq(shown[3].title, "AI 归纳")
Assert.eq(shown[3].text, "• 大家都在夸伏笔。")

-- 失败：提示原因
Digest.run("句", items)
requests[2].cb(nil, "timeout")
Assert.eq(shown[#shown].kind, "toast")
Assert.matches(shown[#shown].text, "timeout")

-- 等待中关掉卡片：取消请求
Digest.run("句", items)
shown[#shown]:close()
Assert.eq(cancelled, 1)

return true
