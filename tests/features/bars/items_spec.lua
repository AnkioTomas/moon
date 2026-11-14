--[[--
阅读页栏组件：目录过滤与文案。
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

package.loaded["features.bars.items"] = nil
local Items = require("features.bars.items")

local top = Items.catalog("top")
local bottom = Items.catalog("bottom")
local top_ids, bottom_ids = {}, {}
for i = 1, #top do top_ids[top[i].id] = true end
for i = 1, #bottom do bottom_ids[bottom[i].id] = true end
Assert.is_true(top_ids.chapter)
Assert.is_true(top_ids.clock)
Assert.is_nil(top_ids.progress_bar)
Assert.is_true(bottom_ids.progress_bar)
Assert.is_true(bottom_ids.percent)

local ctx = Items.sampleContext()
Assert.eq(Items.text("chapter", ctx), "第三章 初见")
Assert.eq(Items.text("title", ctx), "示例书名")
Assert.eq(Items.text("clock", ctx), "12:34")
Assert.eq(Items.text("percent", ctx), "42%")
Assert.eq(Items.text("percent", { percent = 42.375, percent_decimals = true }), "42.38%")
Assert.eq(Items.text("chapter_idx", ctx), "第 3/10 章")
Assert.eq(Items.text("page", ctx), "全书 120/320")
Assert.eq(Items.text("remaining", ctx), "约 30 分钟")
Assert.eq(Items.text("progress_bar", ctx), "")
Assert.eq(Items.text("percent", { percent = 150 }), "100%")
Assert.eq(Items.text("percent", { percent = -3 }), "0%")
Assert.eq(Items.text("page", { page = 1 }), "")
Assert.eq(Items.text("chapter_idx", { chapter_idx = 3 }), "")
Assert.eq(Items.text("chapter_page", ctx), "本章 5/18")
Assert.eq(Items.text("chapter_page", { chapter_page = 5 }), "", "缺本章页数不显示")
Assert.is_true(top_ids.chapter_page)
Assert.is_true(bottom_ids.chapter_page)

-- 进度条用真实主题 Progress 画：它是自绘 Widget，没有 free（曾因 bar:free() 每次重绘崩阅读页）
do
    local Kit = require("support.widget_stubs")
    Kit.install()
    package.loaded["ui.themes.widgets.progress"] = nil
    local bb = Kit.canvas()
    Items.paint(bb, 0, 0, 300, 20, { { id = "progress_bar", align = "left" } }, { percent = 40 }, { bar_h = 6, gap = 4 })
    Assert.eq(bb.ops[1].op, "rect", "进度条画出了轨道")
    Assert.eq(bb.ops[1].w, 300, "唯一的 flex 条目占满宽度")
    Assert.eq(bb.ops[1].y, math.floor((20 - 6) / 2), "单栏进度条与行垂直居中，不单独贴底")

    -- 图标：电量按档位选图标、文字跟在图标后；Wi-Fi 开图标时只画图标
    local TextWidget = require("ui/widget/textwidget")
    local orig_paint = TextWidget.paintTo
    local painted = {}
    TextWidget.paintTo = function(self, _bb, px, py)
        painted[#painted + 1] = { text = self.text, x = px, y = py, w = self:getSize().w, xtext = self.use_xtext }
    end
    package.loaded["ui.themes.widgets.icon"] = { face = function(size) return { icon = size } end }
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "battery", align = "left" }, { id = "wifi", align = "right" } },
        { battery = 50, charging = false, wifi = false },
        { face = { orig_size = 14 }, gap = 4, icons = true })
    local icon_gap = require("device").screen:scaleBySize(2)
    Assert.eq(painted[1].text, "battery_android_3")
    Assert.is_true(painted[1].xtext, "图标名靠 rlig 合成字形，必须走 xtext")
    Assert.eq(painted[2].text, "50%")
    Assert.eq(painted[2].x, #"battery_android_3" * 5 + icon_gap)
    Assert.eq(painted[3].text, "wifi_off")
    Assert.eq(painted[3].x, 300 - #"wifi_off" * 5, "只有图标的条目贴右边")
    Assert.len(painted, 3)

    -- 居中：相对整栏绝对居中；多项按布局顺序成组
    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "clock", align = "center" } },
        { clock = "12:34" },
        { face = { orig_size = 14 }, gap = 4 })
    Assert.eq(painted[1].text, "12:34")
    Assert.eq(painted[1].x, math.floor((300 - #"12:34" * 5) / 2), "单条居中")

    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "clock", align = "center" }, { id = "percent", align = "center" } },
        { clock = "12:34", percent = 42 },
        { face = { orig_size = 14 }, gap = 4 })
    local group_w = #"12:34" * 5 + 4 + #"42%" * 5
    Assert.eq(painted[1].x, math.floor((300 - group_w) / 2), "居中组起点")
    Assert.eq(painted[2].x, painted[1].x + #"12:34" * 5 + 4)
    Assert.eq(painted[2].text, "42%")

    -- flex 组件居中：槽宽是弹性分配的整片剩余宽度，必须居中槽内的内容而不是贴槽左缘
    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "chapter_page", align = "left" }, { id = "title", align = "center" }, { id = "percent", align = "right" } },
        ctx,
        { face = { orig_size = 14 }, gap = 4 })
    local title_w = #"示例书名" * 5
    for _i, p in ipairs(painted) do
        if p.text == "示例书名" then
            Assert.is_true(math.abs(p.x - math.floor((300 - title_w) / 2)) <= 1, "flex 书名居中")
        end
    end

    -- flex 组件靠右：内容右缘贴栏右缘
    painted = {}
    Items.paint(bb, 0, 0, 300, 20,
        { { id = "title", align = "right" } },
        ctx,
        { face = { orig_size = 14 }, gap = 4 })
    Assert.eq(painted[1].text, "示例书名")
    Assert.eq(painted[1].x, 300 - title_w, "flex 书名靠右")

    -- 显式双栏 + 居中书名：拆成两行，书名按整栏真正居中，进度条满宽贴底。
    painted = {}
    local stacked_bb = Kit.canvas()
    Items.paint(stacked_bb, 0, 0, 300, 40,
        {
            { id = "progress_bar", align = "left", row = "down" },
            { id = "title", align = "center", row = "up" },
            { id = "page", align = "right", row = "up" },
        },
        ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
    local title
    local page
    for _i, p in ipairs(painted) do
        if p.text == "示例书名" then title = p end
        if p.text == "全书 120/320" then page = p end
    end
    Assert.not_nil(title, "两行时画出书名")
    Assert.not_nil(page, "两行时画出页码")
    Assert.eq(title.x, math.floor((300 - title_w) / 2), "两行时书名相对整栏真正居中")
    Assert.eq(page.x, 300 - #"全书 120/320" * 5, "页码仍靠右")
    Assert.is_true(title.x + title.w <= page.x, "居中书名不叠到右侧页码")
    Assert.eq(title.y, 40 - 6 - 2 - 10, "书名紧贴进度条上方，不在剩余高度里居中")

    -- 两项居中应成组紧挨（间隔只有 gap），不能把文字宽算两次拉开。
    painted = {}
    Items.paint(Kit.canvas(), 0, 0, 300, 26,
        {
            { id = "progress_bar", align = "left", row = "down" },
            { id = "chapter_idx", align = "center", row = "up" },
            { id = "remaining", align = "center", row = "up" },
        },
        ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
    local a, b
    for _i, p in ipairs(painted) do
        if p.text == "第 3/10 章" then a = p end
        if p.text == "约 30 分钟" then b = p end
    end
    Assert.not_nil(a)
    Assert.not_nil(b)
    Assert.eq(b.x, a.x + a.w + 4, "居中组成组间隔等于 gap")
    local group_w = a.w + 4 + b.w
    Assert.eq(a.x, math.floor((300 - group_w) / 2), "居中组相对整栏居中")

    local bar
    for _i, op in ipairs(stacked_bb.ops) do
        if op.op == "rect" and op.h == 6 and op.w == 300 then
            bar = op
            break
        end
    end
    Assert.not_nil(bar, "两行进度条满宽")
    Assert.eq(bar.y, 40 - 6, "两行进度条贴条带底部")
    Assert.eq(bar.x, 0)

    -- 长书名截断，仍不侵入右侧页码。
    painted = {}
    local long_ctx = {}
    for k, v in pairs(ctx) do long_ctx[k] = v end
    long_ctx.title = string.rep("名", 80)
    Items.paint(Kit.canvas(), 0, 0, 300, 40,
        {
            { id = "progress_bar", align = "left", row = "down" },
            { id = "title", align = "center", row = "up" },
            { id = "page", align = "right", row = "up" },
        },
        long_ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
    local long_title, long_page
    for _i, p in ipairs(painted) do
        if p.text == long_ctx.title then long_title = p end
        if p.text == "全书 120/320" then long_page = p end
    end
    Assert.not_nil(long_title)
    Assert.not_nil(long_page)
    Assert.is_true(long_title.w < #"名" * 80 * 5, "长书名被截断")
    Assert.is_true(long_title.x + long_title.w <= long_page.x, "截断后不叠到页码")

    -- 未开双栏：即使居中 + 进度条也保持单行，进度条只占 flex 槽。
    local single_bb = Kit.canvas()
    Items.paint(single_bb, 0, 0, 300, 20,
        {
            { id = "progress_bar", align = "left" },
            { id = "title", align = "center" },
            { id = "page", align = "right" },
        },
        ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stacked = false })
    local single_bar
    for _i, op in ipairs(single_bb.ops) do
        if op.op == "rect" and op.h == 6 then
            single_bar = op
            break
        end
    end
    Assert.not_nil(single_bar)
    Assert.is_true(single_bar.w < 300, "单栏时进度条不拆成满宽第二行")
    Assert.eq(single_bar.y, math.floor((20 - 6) / 2), "单栏进度条与文字同一行居中")

    local function findBar(bb, height)
        height = height or 6
        for _i, op in ipairs(bb.ops) do
            if op.op == "rect" and op.h == height then return op end
        end
    end
    local function findText(label)
        for _i, p in ipairs(painted) do
            if p.text == label then return p end
        end
    end

    -- 双栏 × 左 / 中 / 右：信息在上，进度条满宽贴底；对齐只影响信息行。
    for _i, case in ipairs({
        { align = "left", label = "示例书名", expect_x = 0 },
        { align = "center", label = "示例书名", expect_x = math.floor((300 - title_w) / 2) },
        { align = "right", label = "示例书名", expect_x = 300 - title_w },
    }) do
        painted = {}
        local bb = Kit.canvas()
        Items.paint(bb, 0, 0, 300, 40,
            {
                { id = "progress_bar", align = "left", row = "down" },
                { id = "title", align = case.align, row = "up" },
            },
            ctx,
            { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
        local text = findText(case.label)
        local bar = findBar(bb)
        Assert.not_nil(text, "双栏 " .. case.align .. " 画出书名")
        Assert.eq(text.x, case.expect_x, "双栏书名对齐 " .. case.align)
        Assert.eq(text.y, 40 - 6 - 2 - 10, "双栏信息紧贴进度条上方")
        Assert.not_nil(bar, "双栏 " .. case.align .. " 有进度条")
        Assert.eq(bar.w, 300, "双栏进度条满宽")
        Assert.eq(bar.y, 40 - 6, "双栏进度条贴底")
    end

    -- 双栏但关掉进度条：不留空行，书名按单行高度垂直居中带内绘制（y 随 20px 行高）。
    painted = {}
    local no_bar = Kit.canvas()
    Items.paint(no_bar, 0, 0, 300, 20,
        { { id = "title", align = "left" } },
        ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
    Assert.eq(findText("示例书名").x, 0)
    Assert.is_nil(findBar(no_bar), "关掉进度条不画空条")
    -- 单行带内垂直居中（文字桩高 10）：不按「信息贴在进度条上方」去排。
    Assert.eq(findText("示例书名").y, math.floor((20 - 10) / 2), "无进度条时按单行排，不留空行")

    -- 双栏偏好但只有进度条：实际按单栏画，满宽在带内居中，不留空信息行。
    painted = {}
    local bar_only = Kit.canvas()
    Items.paint(bar_only, 0, 0, 300, 20,
        { { id = "progress_bar", align = "left" } },
        ctx,
        { face = { orig_size = 14 }, gap = 4, bar_h = 6, stack_gap = 2, stacked = true })
    Assert.len(painted, 0, "只有进度条时没有信息文字")
    local only = findBar(bar_only)
    Assert.not_nil(only)
    Assert.eq(only.w, 300)
    Assert.eq(only.y, math.floor((20 - 6) / 2), "只有进度条时在单行带内居中，不另开信息行")

    -- 复现设置预览截图配置：左章节序号 / 章内页码 / 剩余时间，右百分比，进度条在同一行的 flex 槽里。
    -- 条带用预览单栏 56px 起步；若再按条带贴底，条子会沉到文字下面（用户看到的「单栏还是两行」）。
    local shot_layout = {
        { id = "chapter_idx", align = "left" },
        { id = "chapter_page", align = "left" },
        { id = "remaining", align = "left" },
        { id = "progress_bar", align = "left" },
        { id = "percent", align = "right" },
    }
    local shot_ctx = {}
    for k, v in pairs(ctx) do shot_ctx[k] = v end
    shot_ctx.percent_decimals = true
    painted = {}
    local shot_bb = Kit.canvas()
    local SHOT_W, SHOT_H, SHOT_BAR = 600, 56, 8
    Items.paint(shot_bb, 0, 0, SHOT_W, SHOT_H, shot_layout, shot_ctx, {
        face = { orig_size = 14 }, gap = 4, bar_h = SHOT_BAR, stacked = false,
    })
    local ch = findText("第 3/10 章")
    local cp = findText("本章 5/18")
    local rem = findText("约 30 分钟")
    local pct = findText("42.00%")
    local shot_bar = findBar(shot_bb, SHOT_BAR)
    Assert.not_nil(ch)
    Assert.not_nil(cp)
    Assert.not_nil(rem)
    Assert.not_nil(pct)
    Assert.not_nil(shot_bar)
    local text_y = ch.y
    Assert.eq(cp.y, text_y, "章内页码与章节序号同一行")
    Assert.eq(rem.y, text_y, "剩余时间与章节序号同一行")
    Assert.eq(pct.y, text_y, "百分比与章节序号同一行")
    local expect_bar_y = math.max(0, math.floor((SHOT_H - SHOT_BAR) / 2))
    Assert.eq(shot_bar.y, expect_bar_y, "单栏进度条与文字同一行垂直居中")
    Assert.is_true(shot_bar.y ~= SHOT_H - SHOT_BAR, "单栏进度条不得按 56px 条带贴底")
    -- 垂直方向与文字行重叠，而不是整段落在文字下方。
    Assert.is_true(shot_bar.y < text_y + 10, "进度条顶不超过文字行底")
    Assert.is_true(text_y < shot_bar.y + SHOT_BAR, "文字顶不超过进度条底")
    Assert.is_true(shot_bar.w < SHOT_W, "单栏进度条走本行槽宽，不是满宽第二行")
    Assert.is_true(shot_bar.x >= rem.x + rem.w, "进度条在左侧信息之后")
    Assert.is_true(shot_bar.x + shot_bar.w <= pct.x, "进度条不到右侧百分比")
    Assert.eq(ch.x, 0, "章节序号在最左")
    Assert.eq(pct.x, SHOT_W - pct.w, "百分比靠右")

    -- 同一套配置开双栏：信息在上，进度条满宽贴底。
    painted = {}
    local dual_bb = Kit.canvas()
    local dual_layout = {
        { id = "chapter_idx", align = "left", row = "up" },
        { id = "chapter_page", align = "left", row = "up" },
        { id = "remaining", align = "left", row = "up" },
        { id = "progress_bar", align = "left", row = "down" },
        { id = "percent", align = "right", row = "up" },
    }
    Items.paint(dual_bb, 0, 0, SHOT_W, SHOT_H, dual_layout, shot_ctx, {
        face = { orig_size = 14 }, gap = 4, bar_h = SHOT_BAR, stack_gap = 2, stacked = true,
    })
    local dual_ch = findText("第 3/10 章")
    local dual_pct = findText("42.00%")
    local dual_bar = findBar(dual_bb, SHOT_BAR)
    Assert.not_nil(dual_ch)
    Assert.not_nil(dual_pct)
    Assert.not_nil(dual_bar)
    Assert.eq(dual_bar.w, SHOT_W, "双栏进度条满宽")
    Assert.eq(dual_bar.y, SHOT_H - SHOT_BAR, "双栏进度条贴底")
    Assert.eq(dual_ch.y, SHOT_H - SHOT_BAR - 2 - 10, "双栏信息紧贴进度条上方")
    Assert.eq(dual_pct.y, dual_ch.y)
    Assert.eq(dual_pct.x, SHOT_W - dual_pct.w)
    Assert.is_true(dual_ch.y + 10 <= dual_bar.y, "双栏文字与进度条上下分行")

    local home = Config.dir()
    os.execute("mkdir -p " .. string.format("%q", home))
    local mf = io.open(home .. "/moon-single-bar-row-metrics.txt", "w")
    Assert.not_nil(mf)
    mf:write(string.format(
        "single w=%s h=%s bar_h=%s\nch x=%s y=%s w=%s\ncp x=%s y=%s w=%s\nrem x=%s y=%s w=%s\npct x=%s y=%s w=%s\nbar x=%s y=%s w=%s h=%s\nbuggy_bar_y=%s\ndual ch_y=%s pct_x=%s bar_y=%s bar_w=%s\n",
        SHOT_W, SHOT_H, SHOT_BAR,
        ch.x, ch.y, ch.w, cp.x, cp.y, cp.w, rem.x, rem.y, rem.w,
        pct.x, pct.y, pct.w, shot_bar.x, shot_bar.y, shot_bar.w, SHOT_BAR,
        SHOT_H - SHOT_BAR,
        dual_ch.y, dual_pct.x, dual_bar.y, dual_bar.w
    ))
    mf:close()

    local original_new, original_free = TextWidget.new, TextWidget.free
    local created, freed = 0, 0
    TextWidget.new = function(self, options)
        created = created + 1
        return original_new(self, options)
    end
    TextWidget.free = function(self)
        freed = freed + 1
        return original_free(self)
    end
    local cache = { widgets = {}, keys = {} }
    local cache_opts = { face = { orig_size = 14 }, cache = cache, stacked = false }
    local cache_layout = { { id = "title", align = "left" }, { id = "percent", align = "right" } }
    local cache_ctx = { title = string.rep("a", 100), percent = 42 }
    Items.paint(Kit.canvas(), 0, 0, 100, 30, cache_layout, cache_ctx, cache_opts)
    local first_created, first_freed = created, freed
    Items.paint(Kit.canvas(), 0, 0, 100, 30, cache_layout, cache_ctx, cache_opts)
    Assert.eq(created, first_created, "相同限宽标题重绘不创建控件")
    Assert.eq(freed, first_freed, "相同限宽标题重绘不淘汰控件")
    Items.paint(Kit.canvas(), 0, 0, 120, 30, cache_layout, cache_ctx, cache_opts)
    Assert.eq(created, first_created + 1, "只有限宽变化时重建绘制控件")
    Items.paint(Kit.canvas(), 0, 0, 120, 30, {}, cache_ctx, cache_opts)
    Assert.eq(next(cache.widgets), nil, "清空布局释放测量和绘制控件")
    Assert.eq(next(cache.keys), nil)
    TextWidget.new, TextWidget.free = original_new, original_free

    local original_getSize = TextWidget.getSize
    local text_face, icon_face = { orig_size = 14 }, { orig_size = 14, icon = true }
    TextWidget.getSize = function(self)
        return { w = #self.text * 5, h = self.face.icon and 30 or 21 }
    end
    package.loaded["ui.themes.widgets.icon"] = { face = function() return icon_face end }
    Assert.eq(Items.rowHeight({ { id = "battery" } }, text_face, true, 8), 30,
        "图标比文字高时同样为图标预留空间")
    Assert.eq(Items.rowHeight({ { id = "progress_bar" } }, text_face, true, 24), 24,
        "纯进度条不增加文字行高")
    TextWidget.getSize = original_getSize

    TextWidget.paintTo = orig_paint
    package.loaded["ui.themes.widgets.icon"] = nil
end

-- 图标名随状态变化；开图标时文案省掉前后缀
Assert.eq(Items.glyph("battery", { battery = 100 }), "battery_android_full")
Assert.eq(Items.glyph("battery", { battery = 3 }), "battery_android_0")
Assert.eq(Items.glyph("battery", { battery = 60, charging = true }), "battery_android_bolt")
Assert.eq(Items.glyph("wifi", { wifi = true }), "wifi")
Assert.eq(Items.glyph("brightness", { brightness = 80 }), "brightness_high")
Assert.is_nil(Items.glyph("clock", ctx), "时钟一眼可读，不配图标")
Assert.eq(Items.text("chapter_page", ctx, true), "本章 5/18", "和页码都保留前后缀，避免两栏都是 N/M")
Assert.eq(Items.text("page", ctx, true), "全书 120/320")
Assert.eq(Items.text("chapter_idx", ctx, true), "3/10")
Assert.eq(Items.text("wifi", ctx, true), "")
Assert.eq(Items.text("wifi", ctx), "Wi-Fi")
Assert.eq(Items.text("battery", ctx), "85%")
Assert.eq(Items.text("memory", { memory = 512 }), "运存 512M")
Assert.eq(Items.text("memory", { memory = 1536 }, true), "1.5G", "开图标省前缀、超 1G 换算")
Assert.eq(Items.glyph("memory", { memory = 512 }), "memory")

return true
