--[[--
书摘分享卡片布局：全部主题、有无封面、插画与文案边界。

示例摘文为公有领域苏轼《水调歌头》。

@module tests.features.share.card_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8 = function(v) return { gray = v } end,
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
    }
end
local color_screen = false
package.preload["device"] = function()
    return { screen = { isColorEnabled = function() return color_screen end, scaleBySize = function(_, n) return n end } }
end
package.preload["ui.themes"] = function()
    return { color = function(v) return { rgb = v } end }
end

package.loaded["features.share.card"] = nil
local Card = require("features.share.card")

-- 色板令牌：电纸灰度、彩屏 RGB。Box.style 必须吃数字，不能吃 Color 对象。
Assert.eq(Card.colorToken(0xF6F1E8, 0xF0), 0xF0)
color_screen = true
Assert.eq(Card.colorToken(0xF6F1E8, 0xF0), 0xF6F1E8)
color_screen = false

local SAMPLE = "明月几时有？把酒问青天。不知天上宫阙，今夕是何年。我欲乘风归去，又恐琼楼玉宇，高处不胜寒。"

local function chars(s)
    local n = 0
    for _ in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

local function metrics()
    return {
        dpi = 1,
        face = "cfont",
        bold_face = nil,
        logo = "/tmp/logo.png",
        measure = function(text, width, size, _bold, opts)
            local lh = 1 + ((opts and opts.line_height) or 0.3)
            local per = math.max(1, math.floor(width / math.max(size, 1)))
            return math.ceil(math.max(chars(text), 1) / per) * size * lh
        end,
        measure_width = function(text, size)
            return chars(text) * size
        end,
        bearing = function(size)
            return math.floor(size * 0.5)
        end,
    }
end

Assert.is_true(Card.isStyle("paper"))
Assert.is_false(Card.isStyle("night"), "夜读已并入纸页")
Assert.is_false(Card.isStyle("official"), "公众号长图已下线")
Assert.is_true(Card.isStyle("calendar"))
Assert.is_true(Card.isStyle("scenic"))
Assert.is_true(Card.isStyle("vista"))
Assert.is_false(Card.isStyle("wechat"))
Assert.is_true(Card.hasSwatch("paper"))
Assert.is_true(Card.hasSwatch("classic"))
Assert.is_false(Card.hasSwatch("cinema"), "静影不提供底色色板")
Assert.is_false(Card.hasSwatch("scenic"))
do
    local theme, swatch = Card.migrate("night", "default")
    Assert.eq(theme, "paper")
    Assert.eq(swatch, "night")
    theme, swatch = Card.migrate("night", "blush")
    Assert.eq(theme, "paper")
    Assert.eq(swatch, "blush")
    theme, swatch = Card.migrate("official", "blue")
    Assert.eq(theme, "paper")
    Assert.eq(swatch, "blue")
    theme, swatch = Card.migrate("classic", "default")
    Assert.eq(theme, "classic")
    Assert.eq(swatch, "default")
end
Assert.eq(Card.STYLES[1].id, "calendar")
Assert.eq(Card.GROUP_LABELS.moon, "月读")
Assert.eq(Card.GROUP_LABELS.art, "插画")
Assert.eq(Card.BRAND, "月读")
Assert.is_true(Card.isArtTheme("scenic"))
Assert.is_false(Card.isArtTheme("paper"))

Assert.eq(Card.bookTitle("东坡乐府"), "《东坡乐府》")
Assert.eq(Card.bookTitle("《东坡乐府》"), "《东坡乐府》")
Assert.eq(Card.bookTitle("「已有」"), "「已有」")
Assert.eq(Card.bookTitle("  "), "")
-- 书名号必须整字去掉：Lua 的 [] 会按字节删，把「，与化危」拆成缺字。
local classic_title = "爱，鸡尾酒与生化危机 2023-09-01"
Assert.eq(Card.stripTitleMarks(classic_title), classic_title)
Assert.eq(Card.stripTitleMarks("《" .. classic_title .. "》"), classic_title)
Assert.eq(Card.stripTitleMarks("「东坡乐府」"), "东坡乐府")
Assert.eq(Card.stripTitleMarks("  "), "")
Assert.eq(Card.byline("苏轼", "水调歌头"), "苏轼  ·  水调歌头")
Assert.eq(Card.byline("苏轼", ""), "苏轼")
Assert.eq(Card.byline("", "水调歌头"), "水调歌头")
Assert.eq(Card.byline("", ""), "")

-- 日历文案按东八区。UTC 2024-01-01 00:30 → 上海 08:30，星期一。
do
    local utc = 1704069000
    Assert.eq(os.date("!%Y-%m-%d %H:%M", utc), "2024-01-01 00:30")
    local date = Card.calendarDate(utc)
    Assert.eq(date.year, 2024)
    Assert.eq(date.month, 1)
    Assert.eq(date.mday, 1)
    Assert.eq(date.day, "1")
    Assert.eq(date.meta, "一月  ·  二〇二四")
    Assert.eq(date.week, "星期一")
    Assert.eq(Card.cnYear(2026), "二〇二六")
    Assert.eq(Card.cnMonth(11), "十一月")
    Assert.eq(Card.cnWeekday(1), "星期日")
end

local m = metrics()
local payload = { text = SAMPLE, title = "东坡乐府", authors = "苏轼", chapter = "水调歌头", cover = "/tmp/cover.png" }

local function no_wechat(layout, style)
    local joined = table.concat(Card.texts(layout), "\n")
    Assert.is_nil(joined:find("来自阅读笔记", 1, true), "不要 slogan")
    Assert.is_nil(joined:find("微信", 1, true))
    Assert.is_nil(joined:find("书摘", 1, true), "不要书摘 kicker")
    Assert.eq(layout.brand and layout.brand.text, "月读")
end

-- 纸页（含已迁移的夜读 / 公众号长图）都有摘文、书名、作者、月读标志和大引号。
for _idx, style in ipairs({ "paper", "night", "official" }) do
    local layout = Card.layout(style, payload, 375, m)
    Assert.eq(layout.style, "paper", style .. " 已并入纸页")
    Assert.eq(layout.width, 375)
    Assert.is_true(layout.height > 100)
    Assert.eq(layout.quote.text, SAMPLE)
    Assert.eq(layout.title.text, "《东坡乐府》")
    Assert.eq(layout.byline.text, "苏轼  ·  水调歌头")
    Assert.eq(layout.brand.text, "月读")
    Assert.eq(layout.logo.path, "/tmp/logo.png")
    Assert.not_nil(layout.cover)
    Assert.is_true(layout.cover.x < layout.title.x, "封面在书名左边")
    Assert.is_true(layout.title.x < layout.logo.x, "书名在 logo 左边")
    Assert.is_true(layout.logo.x < layout.brand.x, "logo 在「月读」左边")
    no_wechat(layout, style)
    Assert.not_nil(layout.mark)
    Assert.eq(layout.mark.text, "「")
    Assert.is_nil(layout.banner)
    Assert.is_false(layout.quote.bold)
    Assert.eq(layout.mark.x + layout.mark.bearing, 8)
    Assert.is_true(layout.mark.x < 8, "引号字模左移以抵消左侧留白")
    Assert.is_true(layout.mark.x < layout.quote.x, "引号比正文更靠左")
    if style == "night" then
        Assert.is_true(Card.isDark("paper", layout.opts), "夜读落到纸页夜色")
        Assert.eq(layout.opts.swatch, "night")
    end
end

-- 全部主题都能排出版，页脚左右结构一致，文案不含商标。
for _idx, style in ipairs(Card.STYLES) do
    local layout = Card.layout(style.id, payload, 375, m, { art = style.id == "scenic" and "sunset" or "dawn" })
    Assert.eq(layout.width, 375)
    Assert.is_true(layout.height > 100, style.id .. " 有高度")
    Assert.eq(layout.height, math.floor(layout.height), style.id .. " 高度为整数")
    Assert.eq(layout.quote.text, SAMPLE)
    Assert.eq(layout.title.text, "《东坡乐府》")
    Assert.eq(layout.byline.text, "苏轼  ·  水调歌头")
    Assert.eq(layout.brand.text, "月读")
    local joined = table.concat(Card.texts(layout), "\n")
    Assert.is_nil(joined:find("微信", 1, true))
    Assert.is_nil(joined:find("来自阅读笔记", 1, true))
    if style.id == "calendar" then
        Assert.not_nil(layout.calendar)
        Assert.not_nil(layout.cal_day)
        Assert.not_nil(layout.cal_week)
    end
    if style.id == "classic" then
        Assert.not_nil(layout.frame)
        Assert.eq(layout.running, "东坡乐府")
    end
    if style.id == "cinema" then
        Assert.not_nil(layout.media)
        Assert.not_nil(layout.media.cover)
        Assert.is_nil(layout.cover, "静影有封面时页脚不再放小图")
        Assert.is_true(layout.height >= 420)
    end
    if style.id == "scenic" then
        Assert.not_nil(layout.scenic)
        Assert.is_true(layout.scenic.foot_light, "暮色页脚浅色遮罩")
        Assert.is_true(layout.height >= 520, "画境保留完整插画高度")
    end
    if style.id == "vista" then
        Assert.not_nil(layout.vista)
        Assert.eq(layout.vista.height, 196)
        Assert.is_true(layout.height >= 520)
        Assert.not_nil(layout.bg)
    end
    if style.id == "ink" then
        Assert.not_nil(layout.bar)
        Assert.not_nil(layout.watermark)
    end
    if style.id == "letter" then
        Assert.not_nil(layout.lines)
    end
    if style.id == "brocade" then
        Assert.not_nil(layout.bands)
    end
end

-- 没有封面：不画封面占位，仍然左右布局（左书名，右 logo）。
do
    local layout = Card.layout("paper", {
        text = SAMPLE, title = "东坡乐府", authors = "苏轼", chapter = "水调歌头",
    }, 375, m)
    Assert.is_nil(layout.cover)
    Assert.eq(layout.title.x, 32, "没封面时书名贴左内边距")
    Assert.is_true(layout.title.x < layout.logo.x)
    Assert.eq(layout.title.text, "《东坡乐府》")
    Assert.eq(layout.brand.text, "月读")
end

-- 只有书名、没有作者章节：页脚左边仍是书名。
do
    local layout = Card.layout("paper", { text = SAMPLE, title = "东坡乐府" }, 375, m, { swatch = "night" })
    Assert.is_nil(layout.byline)
    Assert.eq(layout.title.text, "《东坡乐府》")
    Assert.is_true(layout.title.x < layout.logo.x)
end

-- 关闭 logo：右侧品牌消失，书名还在。
do
    local layout = Card.layout("paper", payload, 375, m, { show_logo = false })
    Assert.is_nil(layout.logo)
    Assert.is_nil(layout.brand)
    Assert.eq(layout.title.text, "《东坡乐府》")
end

-- 长卡片选项已废弃：传入 long=true 也不再拉高。
do
    local short = Card.layout("paper", payload, 375, m)
    local ignored = Card.layout("paper", payload, 375, m, { long = true })
    Assert.eq(ignored.height, short.height, "忽略 share_long")
    Assert.eq(ignored.quote.y, short.quote.y)
    local cinema = Card.layout("cinema", payload, 375, m)
    Assert.is_true(cinema.height >= 420)
    local vista = Card.layout("vista", payload, 375, m, { art = "dawn" })
    Assert.is_true(vista.height >= 520)
    Assert.eq(vista.vista.height, 196)
end

-- 画境使用统一的 520 最小高度，短摘文不再按文本裁切画布。
do
    local short = Card.layout("scenic", { text = "明月几时有？", title = "东坡乐府" }, 375, m, { art = "sunset" })
    local long = Card.layout("scenic", payload, 375, m, { art = "sunset" })
    Assert.is_true(short.height >= 520, "短摘文也保留完整插画高度")
    Assert.eq(short.height, 520, "短摘文使用统一最小高度")
    Assert.is_true(long.height >= 520, "长摘文不低于完整插画高度")
end

-- 经典页脚落在内框里；锦书页脚在底部色带之上；手札横格延伸到页脚。
do
    local classic = Card.layout("classic", payload, 375, m)
    Assert.not_nil(classic.frame)
    Assert.is_true(classic.cover.y + classic.cover.h
        <= classic.frame.y + classic.frame.height - classic.frame.inset,
        "经典封面不溢出内框底部")
    local header = Card.layout("classic", {
        text = SAMPLE, title = "《爱，鸡尾酒与生化危机 2023-09-01》", authors = "苏轼",
    }, 375, m)
    Assert.eq(header.running, "爱，鸡尾酒与生化危机 2023-09-01", "经典顶栏保留逗号和「与化危」")
    Assert.eq(header.running_block.text, header.running)
    local running = "爱，鸡尾酒与生化危机 2023-09-01 特别加长纪念版"
    local fitted = Card.layout("classic", {
        text = SAMPLE, title = running, authors = "苏轼",
    }, 375, m)
    Assert.not_nil(fitted.running)
    Assert.is_true(#fitted.running <= #running)
    Assert.matches(fitted.running, "…$" )
    Assert.not_nil(fitted.running:find("，", 1, true), "截断后仍保留 ideographic comma")
    local brocade = Card.layout("brocade", payload, 375, m)
    Assert.not_nil(brocade.bands)
    Assert.is_true(brocade.cover.y + brocade.cover.h <= brocade.height - brocade.bands.height,
        "锦书封面不越过底部色带")
    local letter = Card.layout("letter", payload, 375, m)
    Assert.not_nil(letter.lines)
    Assert.eq(letter.lines.foot_top, letter.cover.y, "手札横格画到页脚上沿")
end

-- 画境：雾林摘文靠上，窗夜靠下；青羽是暗色。
do
    local mist = Card.layout("scenic", payload, 375, m, { art = "mist" })
    local window = Card.layout("scenic", payload, 375, m, { art = "window" })
    local crane = Card.layout("scenic", payload, 375, m, { art = "crane" })
    Assert.is_true(mist.quote.y < window.quote.y, "雾林靠上、窗夜靠下")
    Assert.is_false(mist.scenic.foot_light)
    Assert.is_true(Card.isDark("scenic", { art = "crane" }))
    Assert.is_false(Card.isDark("scenic", { art = "sunset" }))
    Assert.is_true(Card.isDark("scenic", { art = "window" }))
    Assert.not_nil(crane.scenic)
end

-- 自定义底色只作用于排版主题，不覆盖插画。
do
    local paper = Card.layout("paper", payload, 375, m, { swatch = "night" })
    Assert.is_true(Card.isDark("paper", { swatch = "night" }))
    local scenic = Card.layout("scenic", payload, 375, m, { swatch = "night", art = "sunset" })
    Assert.is_false(Card.isDark("scenic", { swatch = "night", art = "sunset" }), "插画主题忽略色板")
    local pal = Card.palette("classic", { swatch = "blue" })
    Assert.not_nil(pal.bg)
end

-- 长摘文在最大高度内截断，带省略号。
do
    local long = string.rep("春江潮水连海平，海上明月共潮生。", 80)
    local layout = Card.layout("paper", { text = long, title = "春江花月夜" }, 375, m)
    Assert.is_true(#layout.quote.text < #long)
    Assert.matches(layout.quote.text, "…$")
    Assert.is_true(layout.height <= 375 * 1.45 + 200)
end

-- 生成的渲染块不含 kicker/slogan；电纸顶条是实心深色，logo 圆形，引号是透明文字块。
do
    local layout = Card.layout("paper", payload, 375, m)
    local blocks = Card.blocks(layout)
    local kinds = {}
    for _idx, b in ipairs(blocks) do
        if b.text then
            Assert.is_nil(tostring(b.text):find("书摘", 1, true))
            Assert.is_nil(tostring(b.text):find("来自阅读笔记", 1, true))
        end
        if b.kind then kinds[#kinds + 1] = b.kind end
        if b.kind == "image" and b.file == "/tmp/logo.png" then
            Assert.is_true(b.circle, "logo 圆形遮罩")
        end
        if b.kind == "image" and b.file == "/tmp/cover.png" then
            Assert.is_nil(b.circle, "封面保持矩形")
        end
    end
    Assert.is_nil(table.concat(kinds, ","):find("hgradient", 1, true), "电纸不用渐变")
    Assert.is_true(table.concat(kinds, ","):find("image", 1, true), "封面和 logo")
    local paper = Card.blocks(Card.layout("paper", payload, 375, m))
    local mark
    for _idx, b in ipairs(paper) do
        if b.text == "「" then mark = b end
        Assert.is_true(b.kind ~= "widget", "引号不用自带底色的 widget")
    end
    Assert.not_nil(mark)
    Assert.is_true(mark.x < 8, "引号字模允许负 x")
    Assert.is_false(mark.box)
end

-- 静影忽略底色色板，始终用默认遮罩。
do
    local default = Card.palette("cinema", { swatch = "default" })
    local blushed = Card.palette("cinema", { swatch = "blush" })
    Assert.eq(default.overlay[1], blushed.overlay[1], "静影不随色板改背景")
end

-- 字体挑选：完整 CJK 衬线优先于 Sans，系统 Songti 也能命中；黑体命中 Sans。
do
    Assert.eq(Card.chooseFont({
        { path = "/a/NotoSansCJKsc-Regular.otf", name = "NotoSansCJKsc-Regular.otf" },
        { path = "/sys/Songti.ttc", name = "Songti.ttc" },
    }), "/sys/Songti.ttc")
    Assert.eq(Card.chooseFont({
        { path = "/a/NotoSerifCJKsc-Regular.otf", name = "NotoSerifCJKsc-Regular.otf" },
        { path = "/sys/Songti.ttc", name = "Songti.ttc" },
    }), "/a/NotoSerifCJKsc-Regular.otf")
    Assert.eq(Card.chooseFont({
        { path = "./fonts/NotoSansCJKsc-Regular.otf", name = "NotoSansCJKsc-Regular.otf" },
    }), "./fonts/NotoSansCJKsc-Regular.otf")
    Assert.eq(Card.chooseFont({
        { path = "/a/NotoSansCJKsc-Regular.otf", name = "NotoSansCJKsc-Regular.otf" },
        { path = "/sys/Songti.ttc", name = "Songti.ttc" },
    }, "hei"), "/a/NotoSansCJKsc-Regular.otf")
    -- 没有楷体时回退宋体。
    Assert.eq(Card.chooseFont({
        { path = "/sys/Songti.ttc", name = "Songti.ttc" },
        { path = "./fonts/NotoSansCJKsc-Regular.otf", name = "NotoSansCJKsc-Regular.otf" },
    }, "kai"), "/sys/Songti.ttc")
end

-- 超长书名用省略号截断，不挤掉右边 logo。
do
    local long = "爱，鸡尾酒与生化危机 2026 特别加长纪念版"
    local layout = Card.layout("paper", {
        text = SAMPLE, title = long, authors = "[韩]赵艺恩 译者：山昇", chapter = "1",
        cover = "/tmp/cover.png",
    }, 375, m)
    Assert.matches(layout.title.text, "…$")
    Assert.is_true(layout.title.x + layout.title.width <= layout.logo.x, "书名不挤到 logo")
    Assert.is_true(layout.logo.x < layout.brand.x)
end

-- 相对路径必须展开成绝对路径再登记，否则 Font:getFace 对不上 fontlist，返回 nil。
do
    local list = {}
    package.loaded["ffi/util"] = {
        realpath = function(path)
            if path == "./fonts/noto/NotoSansCJKsc-Regular.otf" then
                return "/emu/fonts/noto/NotoSansCJKsc-Regular.otf"
            end
        end,
    }
    package.loaded["fontlist"] = {
        fontdir = "./fonts",
        fontlist = list,
        getFontList = function(self)
            return self.fontlist
        end,
    }
    Assert.eq(Card.registerFont("./fonts/noto/NotoSansCJKsc-Regular.otf"),
        "/emu/fonts/noto/NotoSansCJKsc-Regular.otf")
    Assert.eq(list[1], "/emu/fonts/noto/NotoSansCJKsc-Regular.otf")
    Assert.eq(Card.registerFont("/emu/fonts/noto/NotoSansCJKsc-Regular.otf"),
        "/emu/fonts/noto/NotoSansCJKsc-Regular.otf")
    Assert.eq(#list, 1, "同一绝对路径不重复登记")
    Assert.eq(Card.registerFont("cfont"), "cfont")
    package.loaded["ffi/util"] = nil
    package.loaded["fontlist"] = nil
end

-- 指定字体打不开时回退自带 Noto；再不行且允许时回退 cfont。粗体失败不回退 cfont。
do
    package.loaded["ffi/util"] = {
        realpath = function(path)
            if path == "/missing/STHeiti Light.ttc" then return path end
            if path == "/emu/fonts/noto/NotoSansCJKsc-Regular.otf" then return path end
            if path == "./fonts/noto/NotoSansCJKsc-Regular.otf" then
                return "/emu/fonts/noto/NotoSansCJKsc-Regular.otf"
            end
        end,
    }
    package.loaded["fontlist"] = {
        fontdir = "./fonts",
        fontlist = { "./fonts/noto/NotoSansCJKsc-Regular.otf" },
        getFontList = function(self) return self.fontlist end,
    }
    -- fontDirs 需要目录存在才会收录；这里直接测 usableFont 的回退，不依赖扫盘。
    local opened = {}
    package.loaded["ui/font"] = {
        getFace = function(_, font, _size, _index)
            opened[#opened + 1] = font
            if font == "/emu/fonts/noto/NotoSansCJKsc-Regular.otf" or font == "cfont" then
                return { name = font }
            end
            return nil
        end,
    }
    -- bundledFont 找不到（fontDirs 在测试里多半没有 ./fonts）时，usableFont 允许 cfont。
    local path, index = Card.usableFont("/missing/STHeiti Light.ttc", false, true)
    Assert.eq(path, "cfont")
    Assert.is_nil(index)
    -- 先把 bundled Noto 解析成绝对路径，再确认优先于 cfont。
    local noto = Card.registerFont("./fonts/noto/NotoSansCJKsc-Regular.otf")
    Assert.eq(noto, "/emu/fonts/noto/NotoSansCJKsc-Regular.otf")
    path, index = Card.usableFont(noto, false, true)
    Assert.eq(path, "/emu/fonts/noto/NotoSansCJKsc-Regular.otf")
    local bold_path = Card.usableFont("/missing/STHeiti Medium.ttc", true, false)
    Assert.is_nil(bold_path, "粗体打不开时不回退 cfont，留给合成粗体")
    package.loaded["ui/font"] = nil
    package.loaded["ffi/util"] = nil
    package.loaded["fontlist"] = nil
end


-- 字体选择器 id 进入 normalize；未知族名仍回落宋体；缺失插画回落默认。
do
    local n = Card.normalize({
        font = "hei", font_id = "KingHwa_OldSong", font_name = "京华老宋体",
        theme = "scenic", art = "deleted",
    })
    Assert.eq(n.font, "hei")
    Assert.eq(n.font_id, "KingHwa_OldSong")
    Assert.eq(n.font_name, "京华老宋体")
    Assert.eq(n.art, "sunset")
    local fallback = Card.normalize({ font = "nope", font_id = "" })
    Assert.eq(fallback.font, "song")
    Assert.is_nil(fallback.font_id)
end

-- 同族粗体：Regular → Bold（文件得在）。
do
    local dir = "/tmp/moon-share-font-sib"
    require("libs/libkoreader-lfs").mkdir(dir)
    local regular = dir .. "/Song-Regular.ttf"
    local bold = dir .. "/Song-Bold.ttf"
    io.open(regular, "w"):close()
    io.open(bold, "w"):close()
    Assert.eq(Card.boldSibling(regular), bold)
    Assert.is_nil(Card.boldSibling(dir .. "/Missing-Regular.ttf"))
    os.remove(regular)
    os.remove(bold)
    require("libs/libkoreader-lfs").rmdir(dir)
end

-- 选择器字体能解析时用该文件；文件不在则回落自动字体，不崩。
do
    local warns = {}
    package.loaded["utils.log"] = {
        warn = function(...) warns[#warns + 1] = { ... } end,
        info = function() end,
        dbg = function() end,
    }
    package.loaded["ui.fonts"] = {
        pathForId = function(id)
            if id == "KingHwa_OldSong" then return "/fonts/KingHwa_OldSong.ttf" end
            return nil, "字体文件不存在"
        end,
    }
    local usable = Card.usableFont
    Card.usableFont = function(path, bold, allow_cfont)
        if path == "/fonts/KingHwa_OldSong.ttf" and not bold then return path end
        return usable(path, bold, allow_cfont)
    end
    local regular, bold = Card.facesForId("KingHwa_OldSong")
    Assert.eq(regular, "/fonts/KingHwa_OldSong.ttf")
    Assert.is_nil(bold)
    Assert.is_nil(Card.facesForId("missing-font"))
    Assert.is_true(#warns >= 1, "缺失字体会记一条 warn，再回落")

    package.loaded["features.lockscreen.render"] = {
        measureText = function() return 10 end,
        getFace = function() return { name = "cfont" } end,
    }
    package.loaded["ui/rendertext"] = {
        sizeUtf8Text = function() return { xadvance = 8 } end,
    }
    local metrics = Card.defaultMetrics({ font_id = "missing-font", font = "song" })
    Assert.not_nil(metrics.face, "缺失字体回落自动字体，defaultMetrics 不抛错")
    Card.usableFont = usable
    package.loaded["utils.log"] = nil
    package.loaded["ui.fonts"] = nil
    package.loaded["features.lockscreen.render"] = nil
    package.loaded["ui/rendertext"] = nil
end

return true
