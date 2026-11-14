--[[--
用 NotoSansCJKsc 14 号的已测字宽核验布局，不依赖 Python、Pillow 或本机字体树。
度量可用同目录 font_measure.py 手动复核；这里验证几何，不冒充真实渲染。
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["l10n"] = function()
    return { apply = function() end }
end

local Kit = require("support.widget_stubs")
Kit.install()

package.loaded["features.bars.items"] = nil
local Items = require("features.bars.items")

local FONT_SIZE = 14
local widths = {
    [""] = 0,
    ["第 3/10 章"] = 63,
    ["本章 5/18"] = 60,
    ["约 30 分钟"] = 64,
    ["42.00%"] = 48,
    ["42%"] = 29,
    ["示例书名"] = 56,
    ["第三章 初见"] = 73,
    ["全书 120/320"] = 83,
    ["12:34"] = 35,
    ["这是一段很长的书名用来验证溢出时只收缩弹性文字而不压到百分比"] = 420,
    ["85%"] = 29,
    ["40%"] = 29,
    ["Wi-Fi"] = 33,
    ["运存 512M"] = 66,
}

local TextWidget = require("ui/widget/textwidget")
local orig_getSize = TextWidget.getSize
local orig_paint = TextWidget.paintTo
local text_height = 10
TextWidget.getSize = function(self)
    local w = widths[self.text]
    if w == nil then
        error("未预测量的文案，不能退回字体桩: " .. tostring(self.text))
    end
    if self.max_width then
        w = math.min(w, self.max_width)
    end
    return { w = w, h = text_height }
end

local painted = {}
TextWidget.paintTo = function(self, _bb, px, py)
    painted[#painted + 1] = {
        text = self.text,
        x = px,
        y = py,
        w = self:getSize().w,
        h = text_height,
    }
end

local function findBar(bb, height)
    local best
    for _i, op in ipairs(bb.ops) do
        if op.op == "rect" and op.h == height then
            if not best or op.w > best.w then
                best = op
            end
        end
    end
    return best
end

local function findText(label)
    for i = 1, #painted do
        if painted[i].text == label then
            return painted[i]
        end
    end
end

local function noOverlapX(a, b, msg)
    Assert.not_nil(a, (msg or "重叠检查") .. " 缺左项")
    Assert.not_nil(b, (msg or "重叠检查") .. " 缺右项")
    local gap = b.x - (a.x + a.w)
    Assert.is_true(gap >= 0, string.format("%s: %q[%s+%s] 压到 %q[%s] 重叠 %s",
        msg or "重叠", a.text or "bar", a.x, a.w, b.text or "bar", b.x, -gap))
    return gap
end

local cases = {}
local function record(name, band_w, band_h, gap, bar_h, layout, texts, bar)
    local rec = {
        name = name,
        w = band_w,
        h = band_h,
        gap = gap,
        bar_h = bar_h,
        layout = layout,
        texts = texts,
        bar = bar,
    }
    cases[#cases + 1] = rec
    return rec
end

local function paint(band_w, band_h, layout, ctx, opts)
    painted = {}
    local bb = Kit.canvas()
    Items.paint(bb, 0, 0, band_w, band_h, layout, ctx, opts)
    return bb
end

local ctx = Items.sampleContext()
ctx.percent_decimals = true
local shot_layout = {
    { id = "chapter_idx", align = "left" },
    { id = "chapter_page", align = "left" },
    { id = "remaining", align = "left" },
    { id = "progress_bar", align = "left" },
    { id = "percent", align = "right" },
}

-- 1) 截图同款单栏，生产默认间距 6，以及预览测试常用间距 4。
for _i, gap in ipairs({ 4, 6 }) do
    local W, H, BAR = 600, 56, 8
    local bb = paint(W, H, shot_layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local ch = findText("第 3/10 章")
    local cp = findText("本章 5/18")
    local rem = findText("约 30 分钟")
    local pct = findText("42.00%")
    local bar = findBar(bb, BAR)
    Assert.not_nil(ch)
    Assert.not_nil(cp)
    Assert.not_nil(rem)
    Assert.not_nil(pct)
    Assert.not_nil(bar)
    Assert.eq(pct.w, widths["42.00%"], "百分比用真实字宽，不是 #text*5")
    Assert.eq(ch.w, widths["第 3/10 章"])
    Assert.eq(ch.y, cp.y)
    Assert.eq(ch.y, rem.y)
    Assert.eq(ch.y, pct.y)
    noOverlapX(ch, cp, "gap=" .. gap .. " 章节/章页")
    noOverlapX(cp, rem, "gap=" .. gap .. " 章页/剩余")
    noOverlapX({ text = "bar", x = bar.x, w = bar.w }, pct, "gap=" .. gap .. " 条/百分比")
    noOverlapX(rem, { text = "bar", x = bar.x, w = bar.w }, "gap=" .. gap .. " 剩余/条")
    local left_end = rem.x + rem.w
    local right_start = pct.x
    -- 条应填满剩余空隙（扣除左右各一档间距）。
    Assert.eq(bar.x, left_end + gap, "进度条从左侧组之后的空隙起点开始")
    Assert.eq(bar.x + bar.w, right_start - gap, "进度条填到右侧组之前，不留额外空档")
    Assert.eq(bar.y, math.floor((H - BAR) / 2), "单栏条与文字垂直居中")
    record("single_gap_" .. gap, W, H, gap, BAR, shot_layout, { ch, cp, rem, pct }, bar)
end

-- 2) 只有进度条：自然满宽。
do
    local bb = paint(600, 20, { { id = "progress_bar", align = "left" } }, ctx, {
        face = { orig_size = FONT_SIZE }, gap = 6, bar_h = 8, stacked = false,
    })
    local bar = findBar(bb, 8)
    Assert.not_nil(bar)
    Assert.eq(bar.w, 600)
    Assert.eq(bar.x, 0)
    record("bar_only", 600, 20, 6, 8, { { id = "progress_bar", align = "left" } }, {}, bar)
end

-- 3) 窄宽仍能放下非弹性文字：条变短但不重叠。
do
    local gap, BAR, W, H = 4, 8, 260, 40
    -- 63+60+64+48 + 4*4 = 251，剩余 9。
    local bb = paint(W, H, shot_layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local rem = findText("约 30 分钟")
    local pct = findText("42.00%")
    local bar = findBar(bb, BAR)
    Assert.not_nil(bar)
    Assert.eq(bar.w, 9)
    noOverlapX(rem, { text = "bar", x = bar.x, w = bar.w }, "窄宽 剩余/条")
    noOverlapX({ text = "bar", x = bar.x, w = bar.w }, pct, "窄宽 条/百分比")
    record("narrow_remain", W, H, gap, BAR, shot_layout, { rem, pct, findText("第 3/10 章"), findText("本章 5/18") }, bar)
end

-- 4) 放不下时弹性书名收缩，条可为 0，不压百分比。
do
    local long = "这是一段很长的书名用来验证溢出时只收缩弹性文字而不压到百分比"
    local layout = {
        { id = "title", align = "left" },
        { id = "progress_bar", align = "left" },
        { id = "percent", align = "right" },
    }
    local long_ctx = {}
    for k, v in pairs(ctx) do long_ctx[k] = v end
    long_ctx.title = long
    -- 先把 long 字宽补进表（loadWidths 已量过）。
    local gap, BAR, W, H = 4, 8, 200, 40
    local bb = paint(W, H, layout, long_ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local title = findText(long)
    -- TextWidget 在 max_width 下可能被截成更短显示文本；若整句被画出来就用它。
    if not title then
        Assert.is_true(#painted >= 1, "应画出书名")
        for i = 1, #painted do
            if painted[i].text ~= "42.00%" then
                title = painted[i]
                break
            end
        end
    end
    local pct = findText("42.00%")
    Assert.not_nil(title)
    Assert.not_nil(pct)
    noOverlapX(title, pct, "长书名与百分比")
    Assert.is_true(title.w < widths[long], "书名被收缩")
    local bar = findBar(bb, BAR)
    if bar then
        noOverlapX(title, { text = "bar", x = bar.x, w = bar.w }, "长书名/条")
        noOverlapX({ text = "bar", x = bar.x, w = bar.w }, pct, "条/百分比")
    end
    record("long_title_shrink", W, H, gap, BAR, layout, { title, pct }, bar)
end

-- 5) 无剩余：宽度刚好比非弹性文字 + 间距还窄，条不画（宽为 0）。
do
    local gap, BAR, W, H = 4, 8, 240, 40
    -- 需要 251，只给 240。
    local bb = paint(W, H, shot_layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local bar = findBar(bb, BAR)
    Assert.is_nil(bar, "没有剩余宽度时不画进度条")
    local ch = findText("第 3/10 章")
    local pct = findText("42.00%")
    Assert.not_nil(ch)
    Assert.not_nil(pct)
    record("no_remain", W, H, gap, BAR, shot_layout, { ch, findText("本章 5/18"), findText("约 30 分钟"), pct }, nil)
end

-- 6) 居中书名 + 左条对齐选左空隙，右百分比；条不画进书名。
do
    local layout = {
        { id = "progress_bar", align = "left" },
        { id = "title", align = "center" },
        { id = "percent", align = "right" },
    }
    local W, H, gap, BAR = 600, 40, 6, 8
    local bb = paint(W, H, layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local title = findText("示例书名")
    local pct = findText("42.00%")
    local bar = findBar(bb, BAR)
    Assert.not_nil(title)
    Assert.not_nil(pct)
    Assert.not_nil(bar)
    noOverlapX({ text = "bar", x = bar.x, w = bar.w }, title, "居中 条/书名")
    noOverlapX(title, pct, "居中 书名/百分比")
    Assert.is_true(bar.x + bar.w <= title.x, "左对齐进度条待在居中书名左侧空隙")
    record("center_title", W, H, gap, BAR, layout, { title, pct }, bar)
end

-- 7) 通用双栏：上行章节+百分比，下行剩余+进度条。不是「信息上、条下」的特判。
do
    local layout = {
        { id = "chapter_idx", align = "left", row = "up" },
        { id = "percent", align = "right", row = "up" },
        { id = "remaining", align = "left", row = "down" },
        { id = "progress_bar", align = "left", row = "down" },
    }
    local W, H, gap, BAR, stack = 600, 56, 6, 8, 2
    local bb = paint(W, H, layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stack_gap = stack, stacked = true,
    })
    local ch = findText("第 3/10 章")
    local pct = findText("42.00%")
    local rem = findText("约 30 分钟")
    local bar = findBar(bb, BAR)
    Assert.not_nil(ch)
    Assert.not_nil(pct)
    Assert.not_nil(rem)
    Assert.not_nil(bar)
    Assert.eq(ch.y, pct.y, "上行文字同行")
    Assert.is_true(rem.y > ch.y + 9, "剩余时间在下行")
    -- 下行：剩余在左，条占剩余宽度到右边缘。
    Assert.eq(bar.x, rem.x + rem.w + gap)
    Assert.eq(bar.x + bar.w, W)
    noOverlapX(ch, pct, "双栏上行 章节/百分比")
    noOverlapX(rem, { text = "bar", x = bar.x, w = bar.w }, "双栏下行 剩余/条")
    record("dual_mixed_rows", W, H, gap, BAR, layout, { ch, pct, rem }, bar)
end

-- 8) 双栏两行都是文字（无进度条），验证不是进度条专属拆行。
do
    local layout = {
        { id = "chapter_idx", align = "left", row = "up" },
        { id = "chapter_page", align = "right", row = "up" },
        { id = "remaining", align = "center", row = "down" },
        { id = "percent", align = "right", row = "down" },
    }
    local W, H, gap, stack = 600, 40, 6, 2
    paint(W, H, layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, stack_gap = stack, stacked = true,
    })
    local ch = findText("第 3/10 章")
    local cp = findText("本章 5/18")
    local rem = findText("约 30 分钟")
    local pct = findText("42.00%")
    Assert.eq(ch.y, cp.y)
    Assert.eq(rem.y, pct.y)
    Assert.is_true(rem.y > ch.y + 9, "两行文字上下分开")
    noOverlapX(ch, cp, "纯文字上行")
    noOverlapX(rem, pct, "纯文字下行")
    record("dual_text_only", W, H, gap, 0, layout, { ch, cp, rem, pct }, nil)
end

-- 9) 每个底栏组件都可以单独放到下行（与一个上行伙伴一起画）。
do
    local partner = { id = "clock", align = "left", row = "up" }
    local bottom = Items.catalog("bottom")
    local seen = 0
    for i = 1, #bottom do
        local id = bottom[i].id
        if id ~= "clock" then
            local layout = { partner, { id = id, align = "left", row = "down" } }
            local bb = paint(600, 40, layout, ctx, {
                face = { orig_size = FONT_SIZE }, gap = 6, bar_h = 8, stack_gap = 2, stacked = true,
            })
            local clock = findText("12:34")
            Assert.not_nil(clock, id .. " 场景应画出上行时钟")
            if id == "progress_bar" then
                local bar = findBar(bb, 8)
                Assert.not_nil(bar, "进度条可单独放在下行")
                Assert.eq(bar.w, 600, "下行只有进度条时满宽")
                Assert.is_true(bar.y > clock.y, "进度条在下行")
            else
                Assert.is_true(#painted >= 2, id .. " 应在下行画出")
                local down
                for p = 1, #painted do
                    if painted[p].text ~= "12:34" then
                        down = painted[p]
                        break
                    end
                end
                Assert.not_nil(down, id .. " 缺下行文字")
                Assert.is_true(down.y > clock.y + 9, id .. " 应画在下行")
            end
            seen = seen + 1
        end
    end
    Assert.is_true(seen >= 8, "应覆盖大部分底栏组件的行选择")
end

-- 10) 粗条与行高同步：下行仅进度条时行高等于条高，贴在绘制区底部。
do
    local layout = {
        { id = "percent", align = "right", row = "up" },
        { id = "progress_bar", align = "left", row = "down" },
    }
    local W, H, BAR, stack = 600, 56, 24, 2
    local bb = paint(W, H, layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = 6, bar_h = BAR, stack_gap = stack, stacked = true,
    })
    local pct = findText("42.00%")
    local bar = findBar(bb, BAR)
    Assert.not_nil(pct)
    Assert.not_nil(bar)
    Assert.eq(bar.h, BAR)
    Assert.eq(bar.w, W)
    Assert.eq(bar.y, H - BAR, "粗条贴绘制区底，行高跟着条走")
    Assert.eq(pct.y, H - BAR - stack - 10, "上行文字紧贴粗条上方，不留 56px 空白")
    -- 内容块高度由各行 max(文字, 条高) 累加，粗条直接抬高下行。
    Assert.eq((H - BAR) - (pct.y + 10), stack)
    record("thick_bar_dual", W, H, 6, BAR, layout, { pct }, bar)
end

-- 11) 单栏忽略行归属，但仍保留配置（由 layout 层保证）；这里确认单栏全部同排。
do
    local layout = {
        { id = "chapter_idx", align = "left", row = "up" },
        { id = "percent", align = "right", row = "down" },
        { id = "progress_bar", align = "left", row = "down" },
    }
    local W, H, gap, BAR = 600, 56, 6, 8
    local bb = paint(W, H, layout, ctx, {
        face = { orig_size = FONT_SIZE }, gap = gap, bar_h = BAR, stacked = false,
    })
    local ch = findText("第 3/10 章")
    local pct = findText("42.00%")
    local bar = findBar(bb, BAR)
    Assert.eq(ch.y, pct.y, "切单栏后行归属被忽略，全部同排")
    noOverlapX(ch, { text = "bar", x = bar.x, w = bar.w }, "单栏忽略行 章节/条")
    noOverlapX({ text = "bar", x = bar.x, w = bar.w }, pct, "单栏忽略行 条/百分比")
    Assert.eq(bar.x, ch.x + ch.w + gap)
    Assert.eq(bar.x + bar.w, pct.x - gap)
    record("single_ignores_row", W, H, gap, BAR, layout, { ch, pct }, bar)
end

do
    for _align_idx, align in ipairs({ "left", "center", "right" }) do
        for _order_idx, bar_first in ipairs({ true, false }) do
            local bar_slot = { id = "progress_bar", align = align }
            local text_slot = { id = "clock", align = align }
            local layout = bar_first and { bar_slot, text_slot } or { text_slot, bar_slot }
            local bb = paint(300, 30, layout, ctx, {
                face = { orig_size = FONT_SIZE }, bar_h = 8, stacked = false,
            })
            local clock, bar = findText("12:34"), findBar(bb, 8)
            Assert.not_nil(clock)
            Assert.not_nil(bar)
            if bar_first then
                noOverlapX(bar, clock, align .. " 进度条在前")
            else
                noOverlapX(clock, bar, align .. " 进度条在后")
            end
        end
    end
end

do
    local Layout = require("features.bars.layout")
    Kit.sections.bars = {
        book_reader_bar_icons = false,
        book_reader_bottom_bar_stacked = true,
        book_reader_progress_thickness = 8,
    }
    Layout.set("bottom", {
        { id = "percent", align = "right", row = "up" },
        { id = "progress_bar", align = "left", row = "down" },
    })
    for _idx, height in ipairs({ 21, 53 }) do
        text_height = height
        local band_h = Layout.bottomPaintHeight({ text_font_size = 14 })
        local bb = paint(300, band_h, Layout.get("bottom"), ctx, {
            face = { orig_size = FONT_SIZE }, bar_h = 8, stacked = true,
        })
        local pct, bar = findText("42.00%"), findBar(bb, 8)
        Assert.not_nil(pct)
        Assert.not_nil(bar)
        Assert.eq(band_h, height + 2 + 8, "预留高度使用字体行高，不是字号")
        Assert.is_true(pct.y >= 0)
        Assert.eq(bar.y + bar.h, band_h, "实际绘制不超过预留高度")
        Assert.eq(bar.y - (pct.y + pct.h), 2)
    end
    text_height = 10
end

-- 写出真实字宽坐标，供渲染对照图。
local function jsonEncode(v)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if t == "boolean" then return v and "true" or "false" end
    if t == "string" then
        return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
    end
    if t == "table" then
        local n = #v
        if n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local out_dir = Config.dir()
os.execute("mkdir -p " .. string.format("%q", out_dir))
local payload = {
    font_size = FONT_SIZE,
    widths = widths,
    cases = cases,
}
local mf = io.open(out_dir .. "/moon-bar-real-font-metrics.json", "w")
Assert.not_nil(mf)
mf:write(jsonEncode(payload))
mf:close()
local tf = io.open(out_dir .. "/moon-bar-real-font-metrics.txt", "w")
Assert.not_nil(tf)
tf:write(string.format("font_size=%s\n42.00%% stub=%s real=%s\n第 3/10 章 stub=%s real=%s\n",
    FONT_SIZE, #"42.00%" * 5, widths["42.00%"], #"第 3/10 章" * 5, widths["第 3/10 章"]))
for i = 1, #cases do
    local c = cases[i]
    tf:write(string.format("case %s w=%s h=%s gap=%s bar_h=%s bar=%s\n",
        c.name, c.w, c.h, c.gap, c.bar_h,
        c.bar and string.format("x=%s y=%s w=%s", c.bar.x, c.bar.y, c.bar.w) or "none"))
    for j = 1, #c.texts do
        local t = c.texts[j]
        tf:write(string.format("  text %q x=%s y=%s w=%s\n", t.text, t.x, t.y, t.w))
    end
end
tf:close()

TextWidget.getSize = orig_getSize
TextWidget.paintTo = orig_paint

return true
