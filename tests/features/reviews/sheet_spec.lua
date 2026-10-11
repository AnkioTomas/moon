--[[-- features.reviews.sheet：按卡片高度分页、末页自动续拉、离线与失败即时提示。 --]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install()

local online = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return online end }
end
package.loaded["ui/network/manager"] = nil

local source = { calls = {}, cancels = 0 }
function source:paragraphReviewPageAsync(_identity, range, max_idx, cb)
    self.calls[#self.calls + 1] = { range = range, max_idx = max_idx, cb = cb }
    return { cancel = function() self.cancels = self.cancels + 1 end }
end
local identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 3, source = source }
local spot = { range = "1-5", text = "圣人对节帅的品位，一向赞不绝口。", total = 321 }

---@param from integer
---@param n integer
---@return table[]
local function batch(from, n)
    local items = {}
    for i = from, from + n - 1 do
        items[#items + 1] = { id = "r" .. i, author = "读者" .. i, content = "点评" .. i, likes = i, time = 0 }
    end
    return items
end

---@param root table
---@param text string
---@return boolean
local function has(root, text)
    for _idx, value in ipairs(Kit.texts(root)) do
        if value == text then return true end
    end
    return false
end

local Sheet = require("features.reviews.sheet")

-- 未联网：只提示，不开窗、不发请求。
online = false
Sheet.open(identity, spot)
Assert.eq(Kit.shown[#Kit.shown].text, "未联网，无法加载段评")
Assert.len(source.calls, 0)
online = true

-- 先开窗显示「正在加载」，同时拉首批。
Sheet.open(identity, spot)
local sheet = Kit.shown[#Kit.shown]
Assert.eq(sheet.spot, spot)
Assert.len(source.calls, 1)
Assert.eq(source.calls[1].max_idx, 0)
Assert.is_true(has(sheet, "正在加载段评…"))
Assert.is_true(has(sheet, "段评"))

-- 首批 30 条：按卡片高度分成多页（首页先放原句），更多未加载时页码带「+」。
source.calls[1].cb({ items = batch(1, 30), total = 321, max_idx = 30, more = true })
local n = #sheet.pages
Assert.is_true(n >= 2)
Assert.eq(sheet.pages[1][1], 1)
Assert.eq(sheet.pages[n][2], 30)
Assert.is_true(has(sheet, "段评 · 共 321 条"))
Assert.is_true(has(sheet, "1 / " .. n .. "+"))
Assert.is_true(has(sheet, "读者1"))
Assert.is_true(has(sheet, "thumb_up"), "点赞用图标")
Assert.is_true(has(sheet, "account_circle"), "作者前有头像图标")
Assert.is_true(has(sheet, "format_quote"), "原句前有引号图标")
Assert.is_true(has(sheet, os.date("%Y-%m-%d", 0) --[[@as string]]))
Assert.is_false(has(sheet, "读者30"))

-- 翻到末页即预取下一批（不等用户点），且只发一次。
for _page = 2, n - 1 do sheet:turn(1) end
Assert.len(source.calls, 1)
sheet:turn(1)
Assert.eq(sheet.page, n)
Assert.is_true(has(sheet, "读者30"))
Assert.len(source.calls, 2)
Assert.eq(source.calls[2].max_idx, 30)
sheet:turn(1)
Assert.len(source.calls, 2, "续拉在飞时不重复请求")
Assert.eq(sheet.page, n)

-- 续拉回来：追加并翻到用户要的下一页。
source.calls[2].cb({ items = batch(31, 30), total = 321, max_idx = 60, more = false })
Assert.eq(sheet.page, n + 1)
Assert.len(sheet.items, 60)
Assert.is_true(has(sheet, (n + 1) .. " / " .. #sheet.pages))
Assert.is_false(sheet.more)
local last = #sheet.pages
sheet.page = last
sheet:turn(1)
Assert.eq(sheet.page, last, "全部加载完后末页不再翻")
Assert.len(source.calls, 2)
sheet:turn(-1)
Assert.eq(sheet.page, last - 1)

-- 滑动翻页。
Assert.is_true(sheet:onSwipeSheet(nil, { direction = "east" }))
Assert.eq(sheet.page, last - 2)
Assert.is_false(sheet:onSwipeSheet(nil, { direction = "north" }))

-- 超长段评截到一页之内。
online = true
Sheet.open(identity, spot)
local long = Kit.shown[#Kit.shown]
local items = batch(1, 1)
items[1].content = string.rep("长", 2000)
source.calls[3].cb({ items = items, total = 1, max_idx = 1, more = false })
Assert.is_true(long:card(1):getSize().h <= long.body_h)
Assert.is_true(has(long, "1 / 1"))

-- 空结果：显示「暂无段评」。
Sheet.open(identity, spot)
local empty = Kit.shown[#Kit.shown]
source.calls[4].cb({ items = {}, total = 0, max_idx = 0, more = true })
Assert.is_false(empty.more, "空批视为到底，避免无限续拉")
Assert.len(empty.pages, 1)

-- 首批失败：关窗并提示错误。
Sheet.open(identity, spot)
local failed = Kit.shown[#Kit.shown]
source.calls[5].cb(nil, "限流")
Assert.eq(Kit.closed[#Kit.closed], failed)
Assert.eq(Kit.shown[#Kit.shown].text, "限流")

-- 续拉途中离线：立即提示，不发请求。
Sheet.open(identity, spot)
local offline = Kit.shown[#Kit.shown]
source.calls[6].cb({ items = batch(1, 30), total = 321, max_idx = 30, more = true })
online = false
offline.page = #offline.pages - 1
offline:turn(1)
Assert.len(source.calls, 6)
Assert.eq(Kit.shown[#Kit.shown].text, "未联网，无法加载段评")
online = true

-- 关窗取消在飞请求。
offline:turn(-1)
offline:turn(1)
Assert.len(source.calls, 7)
offline:close()
Assert.eq(source.cancels, 1)
