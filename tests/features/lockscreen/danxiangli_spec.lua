--[[--
单向历：myrl 日报 → 农历行（真实接口字段）、没有日报不画农历、三种屏幕尺寸不越界、同一天同一句。
@module tests.features.lockscreen.danxiangli_spec
--]]

local Assert = require("support.assert")
local T = require("features.lockscreen.typo_text")
local Myrl = require("online.myrl")
local Dxl = require("features.lockscreen.danxiangli")

-- api.ankio.net/myrl?type=json 2026-10-15 的真实返回（节选）
local PAYLOAD = [[{"code":200,"data":{"date":{"year":2026,"month":10,"day":15,"week":"星期四","lunar":"农历九月初六","ymd":"2026-10-15"},
"almanac":{"ganzhi":"丙午年 戊戌月 壬戌日","animal":"马","constellation":"天秤","term":"","festival":""},
"holiday":null,"history":[],"news":["n"],"quote":{"hitokoto":"q","from":"f"}}}]]

-- 全局 json stub 不解析；只在这里换真解码。
local OnlineBase = require("online.base")
local saved_decode = OnlineBase.decode
OnlineBase.decode = function(body)
    local data = require("support.json_stub").decode(body)
    return type(data.data) == "table" and data.data or data
end
local daily = Myrl:parse(PAYLOAD)
OnlineBase.decode = saved_decode
local OCT15 = { year = 2026, month = 10, day = 15 }

do -- 解析：真实字段
    Assert.eq(daily.ymd, "2026-10-15")
    Assert.eq(daily.ganzhi, "丙午年 戊戌月 壬戌日")
    Assert.eq(daily.animal, "马")
    Assert.is_nil(daily.term)
end

do -- 日历字段 + 农历行
    local c = Dxl.day(OCT15, daily)
    Assert.eq(c.week_zh, "星期四")
    Assert.eq(c.month_en, "OCTOBER")
    Assert.eq(c.yday, 288)
    Assert.eq(c.lunar.date, "九月初六")
    Assert.eq(c.lunar.ganzhi, "丙午马年 · 戊戌月 · 壬戌日")
    Assert.is_nil(c.lunar.term)
    local termed = Dxl.lunarLines({ lunar = "农历九月初一", ganzhi = "丙午年 戊戌月 丁巳日", animal = "马", term = "寒露" })
    Assert.eq(termed.term, "今日寒露")
    Assert.eq(Dxl.lunarLines({ lunar = "农历八月十五", festival = "中秋节" }).term, "中秋节")
end

do -- 没有日报 / 不是今天的日报：不画农历，不报错
    Assert.is_nil(Dxl.day(OCT15, false).lunar)
    Assert.is_nil(Dxl.lunarLines(nil))
    Assert.is_nil(Dxl.lunarLines({ lunar = "农历" }))
    local saved_current, saved_ensure = Myrl.current, Myrl.ensure
    local ensured = 0
    Myrl.ensure = function() ensured = ensured + 1 end
    Myrl.current = function() return nil end
    Assert.is_nil(Dxl.day(OCT15).lunar)
    Myrl.current = function() return daily end
    Assert.eq(Dxl.day(OCT15).lunar.date, "九月初六")
    Assert.is_nil(Dxl.day({ year = 2026, month = 10, day = 16 }).lunar) -- 昨天的缓存不用
    Assert.is_true(ensured >= 3)
    local ops = Dxl.plan(Dxl.day(OCT15, false), { text = "没有农历也要排得下。", title = "", author = "" }, 600, 800,
        function(text, px) return #require("utils.text").chars(text) * px end)
    for _k, op in ipairs(ops) do Assert.is_true(op.s ~= "九月初六") end
    Myrl.current, Myrl.ensure = saved_current, saved_ensure
end

local function measure(text, px)
    local w = 0
    for _idx, ch in ipairs(require("utils.text").chars(text)) do w = w + (#ch == 1 and px * 0.55 or px) end
    return w
end

local quotes = {
    { text = "我们每个人，都对所有人负有罪责，而我比所有人更有罪。", title = "卡拉马佐夫兄弟", author = "陀思妥耶夫斯基" },
    { text = string.rep("很长的一句划线，", 10), title = "", author = "" },
    { text = "To go wrong in one's own way is better than to go right in someone else's.", title = "Crime", author = "F. D." },
}

for _idx, size in ipairs({ { 1072, 1448 }, { 600, 800 }, { 1448, 1072 } }) do
    local w, h = size[1], size[2]
    for _i, date in ipairs({ { year = 2026, month = 10, day = 15 }, { year = 2023, month = 12, day = 31 } }) do
        for _j, q in ipairs(quotes) do
            local ops = Dxl.plan(Dxl.day(date, date.day == 15 and daily or false), q, w, h, measure)
            Assert.is_true(#ops > 10)
            -- 正文都在页脚细线之上（页脚线是最低的那条横线）
            local foot = 0
            for _k, op in ipairs(ops) do if op.t == "rect" and op.h <= 2 and op.y > foot then foot = op.y end end
            for _k, op in ipairs(ops) do
                if op.t == "text" and op.s ~= "MOON · 月读" and not op.s:match("^NO%.") then
                    Assert.is_true(op.y + op.size <= foot, w .. "x" .. h .. " overlaps footer: " .. op.s)
                end
            end
            for _k, op in ipairs(ops) do
                if op.t == "text" then
                    local right = op.x + measure(op.s, op.size)
                    Assert.is_true(op.x >= 0 and right <= w + op.size, w .. "x" .. h .. " overflow x: " .. op.s)
                    Assert.is_true(op.y >= 0 and op.y + op.size <= h + 1, w .. "x" .. h .. " overflow y: " .. op.s)
                else
                    Assert.is_true(op.x >= 0 and op.x + op.w <= w and op.y + op.h <= h, "rect overflow")
                end
            end
        end
    end
end

do -- 同一天同一句，换天换句；没有划线用内置句子
    local items = {}
    for i = 1, 5 do items[i] = { text = "第" .. i .. "条划线的内容", title = "书", author = "" } end
    local a = Dxl.day({ year = 2026, month = 10, day = 15 }, false)
    local b = Dxl.day({ year = 2026, month = 10, day = 16 }, false)
    Assert.eq(Dxl.pickQuote(a, items).text, Dxl.pickQuote(a, items).text)
    Assert.is_true(Dxl.pickQuote(a, items).text ~= Dxl.pickQuote(b, items).text)
    Assert.is_true(Dxl.pickQuote(a, {}).text ~= nil)
end

return true
