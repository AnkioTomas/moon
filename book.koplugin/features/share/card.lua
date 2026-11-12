--[[--
书摘分享卡片：按主题把摘文排成 PNG，经锁屏渲染器写出。

设计宽 375 CSS 像素，默认 3x 输出 1125 宽。字体按宋/黑/楷/仿挑选完整 CJK，
没有则回退 KOReader 自带 Noto Sans CJK。页脚左右排布：左封面（可选）+ 书名，
右月读标志（可关）。品牌只出现「月读」。

@module koplugin.book.features.share.card
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Theme = require("ui.themes")
local Text = require("utils.text")
local Setting = require("features.share.setting")
local _ = require("gettext")

local Card = {}

--- 设计稿宽度（CSS 像素）；输出宽度按它等比放大。
Card.DESIGN_WIDTH = 375

--- 输出目标宽度：接近预览 3x 导出，分享到手机仍清晰。
Card.OUTPUT_WIDTH = 1125

Card.BRAND = _("月读")
Card.QUOTE_MARK = "「"

--- 主题列表（编辑页横滑顺序）；group 表示分组标签出现在该项之前。
Card.STYLES = {
    { id = "calendar", label = _("日历") },
    { id = "classic", label = _("经典") },
    { id = "ink", label = _("墨白") },
    { id = "cinema", label = _("静影") },
    { id = "letter", label = _("手札") },
    { id = "brocade", label = _("锦书") },
    { id = "paper", label = _("纸页摘录") },
    { id = "scenic", label = _("画境"), group = "art" },
    { id = "vista", label = _("远山"), group = "art" },
}

Card.GROUP_LABELS = {
    moon = _("月读"),
    art = _("插画"),
}

Card.FONTS = {
    { id = "song", label = _("宋体") },
    { id = "hei", label = _("黑体") },
    { id = "kai", label = _("楷体") },
    { id = "fang", label = _("仿宋") },
}

--- 排版主题的底色色板（画境 / 远山不用这些，改走插画）。
Card.SWATCHES = {
    { id = "default", label = _("默认") },
    { id = "paper", label = _("米白") },
    { id = "white", label = _("纯白") },
    { id = "night", label = _("夜色") },
    { id = "ink", label = _("淡墨") },
    { id = "slate", label = _("青灰") },
    { id = "blush", label = _("浅胭脂") },
    { id = "blue", label = _("素蓝") },
}

--- 画境插画：tone / foot_light / quote 对应设计稿叠字区域。
Card.SCENIC = {
    sunset    = { id = "sunset",    file = "sunset.jpg",    label = _("暮色"), tone = "light", foot_light = true,  quote = "mid" },
    crane     = { id = "crane",     file = "crane.jpg",     label = _("青羽"), tone = "dark",  foot_light = false, quote = "mid" },
    moon      = { id = "moon",      file = "moon.jpg",      label = _("月影"), tone = "dark",  foot_light = false, quote = "mid" },
    mist      = { id = "mist",      file = "mist.jpg",      label = _("雾林"), tone = "light", foot_light = false, quote = "high" },
    window    = { id = "window",    file = "window.jpg",    label = _("窗夜"), tone = "dark",  foot_light = false, quote = "low" },
    botanical = { id = "botanical", file = "botanical.jpg", label = _("草木"), tone = "light", foot_light = false, quote = "mid" },
    city      = { id = "city",      file = "city.jpg",      label = _("远眺"), tone = "light", foot_light = true,  quote = "mid" },
}

Card.SCENIC_ORDER = { "sunset", "crane", "moon", "mist", "window", "botanical", "city" }

--- 远山风景（顶部画面，底部纸页书摘）。
Card.VISTA = {
    dawn = { id = "dawn", file = "dawn.jpg", label = _("晨岚") },
    dusk = { id = "dusk", file = "dusk.jpg", label = _("暮山") },
    day  = { id = "day",  file = "day.jpg",  label = _("青岭") },
}

Card.VISTA_ORDER = { "dawn", "dusk", "day" }

local STYLE_IDS = {}
for _idx, style in ipairs(Card.STYLES) do STYLE_IDS[style.id] = true end

local DARK_THEMES = { cinema = true }
local DARK_SWATCHES = { night = true, ink = true }
local SWATCH_HEX = Setting.SWATCH_HEX
for _idx, item in ipairs(Card.SWATCHES) do
    item.hex = SWATCH_HEX[item.id]
end

---@param id string
---@return boolean
function Card.isStyle(id)
    return STYLE_IDS[id] == true
end

---@param id string|nil
---@return boolean
function Card.isArtTheme(id)
    return id == "scenic" or id == "vista"
end

--- 静影用封面作背景，不提供底色色板；插画主题改走插画行。
---@param id string|nil
---@return boolean
function Card.hasSwatch(id)
    return not Card.isArtTheme(id) and id ~= "cinema"
end

--- 已下线主题的迁移：夜读并入纸页的夜色色板；公众号长图改走纸页。
Card.migrate = Setting.migrateTheme

--- 书名加上书名号（已有《「『 则不重复）。
---@param name string|nil
---@return string
function Card.bookTitle(name)
    name = Text.trim(tostring(name or ""))
    if name == "" then return "" end
    local prefix = name:sub(1, 3)
    if prefix == "《" or prefix == "「" or prefix == "『" then return name end
    return "《" .. name .. "》"
end

--- 去掉书名号。必须整字替换：Lua 的 [] 按字节匹配，会拆掉「，与化危」这类字。
---@param name string|nil
---@return string
function Card.stripTitleMarks(name)
    name = Text.trim(tostring(name or ""))
    if name == "" then return "" end
    return (name:gsub("《", ""):gsub("》", ""):gsub("「", ""):gsub("」", ""):gsub("『", ""):gsub("』", ""))
end

--- 作者与章节用间隔点拼接；缺一项则只留下有的。
---@param author string|nil
---@param chapter string|nil
---@return string
function Card.byline(author, chapter)
    local parts = {}
    author = Text.trim(tostring(author or ""))
    chapter = Text.trim(tostring(chapter or ""))
    if author ~= "" then parts[#parts + 1] = author end
    if chapter ~= "" then parts[#parts + 1] = chapter end
    return table.concat(parts, "  ·  ")
end

--- 灰度屏用高对比灰度令牌，彩屏用设计稿 RGB 令牌。返回数字，供 Box.style / Theme.color 使用。
---@param rgb number
---@param gray number
---@return number
function Card.colorToken(rgb, gray)
    local Screen = Device.screen
    if Screen.isColorEnabled and Screen:isColorEnabled() then
        return rgb
    end
    return gray
end

--- 灰度屏用高对比 Color8，彩屏用设计稿颜色。不要把信息只放在浅色渐变里。
---@param rgb number
---@param gray number
---@return any
function Card.color(rgb, gray)
    local token = Card.colorToken(rgb, gray)
    local Screen = Device.screen
    if Screen.isColorEnabled and Screen:isColorEnabled() then
        return Theme.color(token)
    end
    return Blitbuffer.Color8(token)
end

local DIGITS = { "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local MONTHS = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二" }
local WEEKS = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" }

---@param year number
---@return string
function Card.cnYear(year)
    return (tostring(year):gsub("%d", function(d)
        return DIGITS[tonumber(d) + 1]
    end))
end

---@param month number
---@return string
function Card.cnMonth(month)
    return (MONTHS[tonumber(month)] or "") .. "月"
end

---@param wday number os.date("*t").wday，1=星期日
---@return string
function Card.cnWeekday(wday)
    return WEEKS[tonumber(wday)] or ""
end

--- 按 Asia/Shanghai（东八区，无夏令时）取日历文案。可传入 now 方便测试。
---@param now number|nil unix 时间
---@return { meta: string, day: string, week: string, year: number, month: number, mday: number }
function Card.calendarDate(now)
    -- !*t 是 UTC；加上 8 小时就是上海的日历日。
    local t = os.date("!*t", (tonumber(now) or os.time()) + 8 * 3600)
    return {
        meta = Card.cnMonth(t.month) .. "  ·  " .. Card.cnYear(t.year),
        day = tostring(t.day),
        week = Card.cnWeekday(t.wday),
        year = t.year,
        month = t.month,
        mday = t.day,
    }
end

---@param opts table|nil
---@return table
function Card.normalize(opts)
    opts = opts or {}
    local state = Setting.normalize(opts)
    local theme, art = state.theme, state.art
    if theme == "scenic" then
        if not (art and Card.SCENIC[art]) then art = "sunset" end
    elseif theme == "vista" then
        if not (art and Card.VISTA[art]) then art = "dawn" end
    elseif theme then
        art = nil
    elseif art and not (Card.SCENIC[art] or Card.VISTA[art]) then
        art = nil
    end
    return {
        theme = theme,
        font = state.font,
        font_id = state.font_id,
        font_name = state.font_name,
        swatch = state.swatch,
        art = art,
        long = false,
        show_logo = state.show_logo,
        now = opts.now,
        art_path = opts.art_path,
    }
end

---@param theme string
---@param opts table|nil
---@return boolean
function Card.isDark(theme, opts)
    opts = opts or {}
    local swatch
    theme, swatch = Card.migrate(theme, opts.swatch)
    if theme == "scenic" then
        local conf = Card.SCENIC[opts.art or "sunset"] or Card.SCENIC.sunset
        return conf.tone == "dark"
    end
    if theme == "vista" then return false end
    if swatch and swatch ~= "default" then return DARK_SWATCHES[swatch] == true end
    return DARK_THEMES[theme] == true
end

-- 各主题默认色与排版尺寸（CSS 像素）。
local THEME = {
    calendar = {
        bg = 0xFAF8F4, ink = 0x2A2622, muted = 0x8A8176, line = 0xE6DFD4, mark = 0xC45C3E,
        quote_size = 18, quote_leading = 0.9, quote_bold = false,
        pad_x = 32, pad_top = 26, pad_bottom = 20, foot_gap = 20, rule_pad = 14,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        long_min = 600, long_pad_top = 36, long_pad_bottom = 28, day_size = 68, long_day_size = 80,
    },
    classic = {
        bg = 0xF4ECDB, ink = 0x2A241C, muted = 0x8A7D6B, line = 0xC4B8A4,
        quote_size = 18, quote_leading = 1.05, quote_bold = false,
        pad_x = 22, pad_top = 22, pad_bottom = 18, inner_pad_x = 18, inner_pad_top = 22, inner_pad_bottom = 14,
        foot_gap = 16, rule_pad = 14,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 13, byline_size = 11, brand_size = 12, brand_bold = false,
        long_min = 600, long_pad_top = 28, long_pad_bottom = 24,
    },
    ink = {
        bg = 0xFFFFFF, ink = 0x141414, muted = 0x6A6A6A, line = 0xE8E8E8, mark = 0xF0F0F0,
        quote_size = 18, quote_leading = 0.9, quote_bold = false,
        pad_x = 36, pad_top = 36, pad_bottom = 24, bar_gap = 22, foot_gap = 36, rule_pad = 16,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        long_min = 600, long_pad_top = 52, long_pad_bottom = 36, mark_size = 150,
    },
    cinema = {
        bg = 0x161310, ink = 0xF4EEE4, muted = 0xD5CBBD, line = 0x3A3530,
        quote_size = 20, quote_leading = 0.9, quote_bold = false,
        pad_x = 32, pad_top = 40, pad_bottom = 24, foot_gap = 28, rule_pad = 16,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        min_h = 420, long_min = 667, long_pad_top = 64,
    },
    letter = {
        bg = 0xF3E8CC, ink = 0x3A3226, muted = 0x8A7B64, line = 0xE0D0A8,
        rule_color = 0xE3D3AD, margin_line = 0xD9B6A4,
        quote_size = 17, quote_leading = 0, quote_bold = false, rule = 32, quote_pad_top = 36,
        pad_x = 28, pad_left = 32, pad_top = 8, pad_bottom = 18, foot_gap = 12, rule_pad = 14,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 13, byline_size = 11, brand_size = 12, brand_bold = false,
        long_min = 600, long_pad_bottom = 28,
    },
    brocade = {
        bg = 0xF6E7C9, ink = 0x3A2420, muted = 0x8A6558, line = 0xE0C9A0, band = 0x6B2B2B, gold = 0xD4B56A,
        quote_size = 18, quote_leading = 0.95, quote_bold = false,
        pad_x = 32, pad_top = 28, pad_bottom = 12, band_h = 20, foot_gap = 20, rule_pad = 14,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 13, byline_size = 11, brand_size = 12, brand_bold = false,
        long_min = 600,
    },
    paper = {
        bg = 0xF6F1E8, ink = 0x2C271F, muted = 0x8A8176, line = 0xE4DACB, mark = 0xD7CBB8,
        quote_size = 20, quote_leading = 0.9, quote_bold = false,
        pad_x = 32, pad_top = 28, pad_bottom = 24, quote_top = 44, foot_gap = 28, rule_pad = 16,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        mark_size = 86, long_min = 600, long_pad_top = 44, long_pad_bottom = 32,
    },
    scenic = {
        bg = 0x1A1815, ink = 0xF4EEE4, muted = 0xB8B0A4, line = 0x3A3530,
        quote_size = 17, quote_leading = 0.95, quote_bold = false,
        pad_x = 32, pad_top = 52, pad_bottom = 18, foot_pad_x = 20, foot_pad_top = 14, foot_gap = 20,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        min_h = 520,
    },
    vista = {
        bg = 0xF7F4EE, ink = 0x2A2622, muted = 0x8A8176, line = 0xEBE4D8,
        quote_size = 16.5, quote_leading = 1.0, quote_bold = false,
        pad_x = 28, pad_top = 28, pad_bottom = 18, foot_pad_x = 20, foot_pad_top = 8, foot_gap = 8, art_h = 196, long_art_h = 240,
        cover_w = 36, cover_h = 48, logo = 22, title_size = 14, byline_size = 11, brand_size = 12, brand_bold = false,
        min_h = 520, long_min = 667,
    },
}

local CINEMA_OVERLAY = {
    default = { 0x16120E, 0x42, 0x080605, 0x84 },
    paper   = { 0x282014, 0x40, 0x140E08, 0x80 },
    white   = { 0x141414, 0x38, 0x000000, 0x78 },
    night   = { 0x0A0A08, 0x55, 0x000000, 0x88 },
    ink     = { 0x141414, 0x48, 0x000000, 0x86 },
    slate   = { 0x141C1E, 0x48, 0x080C0E, 0x86 },
    blush   = { 0x321818, 0x42, 0x140808, 0x84 },
    blue    = { 0x101C30, 0x45, 0x060A18, 0x86 },
}

---@param hex number
---@param dark boolean
---@return number
local function grayOf(hex, dark)
    if dark then return 0x1A end
    local r = math.floor(hex / 0x10000)
    local g = math.floor(hex / 0x100) % 0x100
    local b = hex % 0x100
    return math.max(0, math.min(255, math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)))
end

---@param theme string
---@param opts table
---@return table
function Card.palette(theme, opts)
    opts = opts or {}
    theme, opts.swatch = Card.migrate(theme, opts.swatch)
    local spec = THEME[theme] or THEME.paper
    local dark = Card.isDark(theme, opts)
    local bg, ink, muted, line, mark = spec.bg, spec.ink, spec.muted, spec.line, spec.mark
    local rule_color, margin_line = spec.rule_color, spec.margin_line
    if theme == "scenic" then
        local conf = Card.SCENIC[opts.art or "sunset"] or Card.SCENIC.sunset
        if conf.tone == "dark" then
            ink, muted, line, dark = 0xF4EEE4, 0xB8B0A4, 0x3A3530, true
        else
            ink, muted, line, dark = 0x2A241C, 0x7A7368, 0xC4B8A4, false
        end
    elseif Card.hasSwatch(theme) and opts.swatch and opts.swatch ~= "default" then
        bg = SWATCH_HEX[opts.swatch] or bg
        if dark then
            ink, muted, line = 0xEFE8DC, 0x9A9186, 0x3A3530
            if theme == "paper" then
                -- 夜色色板沿用原先「夜读」主题的线色与引号色。
                if opts.swatch == "night" then
                    line, mark = 0x2D2923, 0x3C372F
                else
                    mark = 0x5A544C
                end
            end
            if theme == "ink" then mark = 0x2A2A28; line = 0x333333 end
            if theme == "calendar" then mark = 0xE08A6C end
            if theme == "letter" then rule_color, margin_line = 0x3A3428, 0x5A4038 end
        else
            ink, muted, line = 0x2C271F, 0x8A8176, 0xD4CBBE
            if theme == "paper" then mark = 0xCBBCA6 end
            if theme == "ink" then line = 0xE8E8E8; mark = 0xF0F0F0 end
            if theme == "calendar" then mark = 0xC45C3E end
        end
    end
    local function tone(rgb, light_g, dark_g)
        if rgb == nil then return nil end
        return Card.color(rgb, dark and (dark_g or 0xF0) or (light_g or 0x2A))
    end
    return {
        bg = Card.color(bg, grayOf(bg, (theme == "cinema" or theme == "paper") and dark or (theme == "scenic" and dark))),
        ink = tone(ink, 0x2A, 0xF0),
        muted = tone(muted, 0x88, 0xA0),
        line = tone(line, 0xDC, 0x3A),
        mark = mark and tone(mark, 0xC0, 0x58) or nil,
        band = spec.band and Card.color(spec.band, 0x2A) or nil,
        gold = spec.gold and Card.color(spec.gold, 0xAA) or nil,
        rule_color = rule_color and Card.color(rule_color, dark and 0x3A or 0xD0) or nil,
        margin_line = margin_line and Card.color(margin_line, dark and 0x5A or 0xB0) or nil,
        dark = dark,
        foot_light = theme == "scenic" and (Card.SCENIC[opts.art or "sunset"] or Card.SCENIC.sunset).foot_light or false,
        foot_ink = nil,
        foot_muted = nil,
        banner = nil,
        overlay = (theme == "cinema" and CINEMA_OVERLAY.default) or CINEMA_OVERLAY[opts.swatch or "default"] or CINEMA_OVERLAY.default,
        spec = spec,
    }
end

local FONT_PATTERNS = {
    song = {
        regular = {
            "Serif.*CJK.*Regular", "Serif.*CJK.*Medium", "SerifSC.*Regular",
            "SourceHanSerif.*Regular", "NotoSerifCJKsc%-Regular", "NotoSerifSC%-Regular",
            "Serif.*CJK", "SerifSC", "SourceHanSerif", "NotoSerifCJK", "NotoSerifSC",
            "Songti", "STSong", "^Song%.", "^song%.",
        },
        bold = {
            "Serif.*CJK.*Bold", "SerifSC.*Bold", "SourceHanSerif.*Bold",
            "NotoSerifCJK.*Bold", "NotoSerifSC.*Bold", "Songti.*Bold", "NotoSansCJK.*Bold",
        },
        reject = "Bold",
    },
    hei = {
        regular = {
            "NotoSansCJKsc%-Regular", "NotoSansSC%-Regular", "Sans.*CJK.*Regular",
            "SourceHanSans.*Regular", "NotoSansCJKsc", "NotoSansSC%-",
            "SourceHanSans", "PingFang", "HiraginoSansGB", "HiraginoSans",
            "STHeiti", "Heiti", "YaHei",
        },
        bold = {
            "NotoSansCJKsc%-Bold", "NotoSansCJK.*Bold", "SourceHanSans.*Bold",
            "STHeiti.*Medium", "Heiti.*Medium", "Heiti.*Bold", "YaHei.*Bold",
        },
        reject = "Serif|Bold|Italic",
    },
    kai = {
        regular = { "LXGWWenKai", "WenKai", "Kaiti", "STKaiti", "KaiTi", "KaitiSC" },
        bold = { "Kaiti.*Bold", "STKaiti.*Bold", "WenKai.*Bold" },
        reject = "Bold",
    },
    fang = {
        regular = { "FangSong", "STFangsong", "FangSong_GB", "BiauKai" },
        bold = { "FangSong.*Bold", "STFangsong.*Bold" },
        reject = "Bold",
    },
}

--- 从已扫到的字体文件里按家族挑完整 CJK。楷/仿找不到则回退宋体，宋体再回退 Sans CJK。
---@param found { path: string, name: string }[]
---@param family string|nil song/hei/kai/fang
---@return string regular, string|nil bold
function Card.chooseFont(found, family)
    family = family or "song"
    if not FONT_PATTERNS[family] then family = "song" end
    table.sort(found, function(a, b) return a.name < b.name end)
    local function match(patterns, reject)
        for _idx, pat in ipairs(patterns) do
            for _i, item in ipairs(found) do
                if item.name:match(pat) and not (reject and item.name:match(reject)) then
                    return item.path
                end
            end
        end
    end
    local pats = FONT_PATTERNS[family]
    -- 不把 Kindle 没有的字体打进包：机器上有完整 CJK 就用，没有再回退自带 Sans。
    local regular = match(pats.regular, pats.reject)
    local bold = pats.bold and match(pats.bold) or nil
    if not regular and family ~= "song" and family ~= "hei" then
        return Card.chooseFont(found, "song")
    end
    if not regular and family == "song" then
        regular = match({ "NotoSansCJKsc%-Regular" }) or "NotoSansCJKsc-Regular.otf"
        if not bold then bold = match({ "NotoSansCJK.*Bold" }) end
    end
    if not regular then
        regular = match({ "NotoSansCJKsc%-Regular" }) or "NotoSansCJKsc-Regular.otf"
    end
    return regular, bold
end

--- 插件 / KOReader 字体目录，以及系统、用户字体目录（含一层子目录）。
---@return string[]
function Card.fontDirs()
    local lfs = require("libs/libkoreader-lfs")
    local dirs = { "./fonts", "./fonts/noto" }
    local ok_list, FontList = pcall(require, "fontlist")
    if ok_list and type(FontList.fontdir) == "string" then
        dirs[#dirs + 1] = FontList.fontdir
    end
    dirs[#dirs + 1] = require("utils.paths").fontsDir()
    dirs[#dirs + 1] = require("ui.fonts").settingsFontsDir()
    local home = os.getenv("HOME") or ""
    local extra = {
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
        "/Library/Fonts",
        "/usr/share/fonts",
        "/usr/local/share/fonts",
        "/system/fonts",
    }
    if home ~= "" then
        extra[#extra + 1] = home .. "/Library/Fonts"
        extra[#extra + 1] = home .. "/.local/share/fonts"
        extra[#extra + 1] = home .. "/.fonts"
    end
    for _idx, dir in ipairs(extra) do
        dirs[#dirs + 1] = dir
    end
    local out, seen = {}, {}
    local function add(dir)
        if type(dir) ~= "string" or dir == "" or seen[dir] then return end
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        seen[dir] = true
        out[#out + 1] = dir
    end
    for _idx, dir in ipairs(dirs) do
        add(dir)
        if type(dir) == "string" and lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name:sub(1, 1) ~= "." then
                    add(dir .. "/" .. name)
                end
            end
        end
    end
    return out
end

--- 收成绝对路径并登记进 FontList。
--- 相对路径若不展开，Font:getFace 会在 fontdir 下再拼一层，并用相对路径去 fontlist 里做模式匹配，
--- 对不上已经扫到的绝对路径，于是返回 nil；TextBoxWidget 随即在 getAdjustedFace 崩溃。
---@param path string
---@return string
function Card.registerFont(path)
    if type(path) ~= "string" or path == "" or path == "cfont" then return path end
    local abs = path
    local ok_util, ffiutil = pcall(require, "ffi/util")
    if ok_util and ffiutil.realpath then
        abs = ffiutil.realpath(path) or path
    end
    if abs:sub(1, 1) ~= "/" then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.currentdir then
            local candidate = lfs.currentdir() .. "/" .. path:gsub("^%./", "")
            if lfs.attributes(candidate, "mode") == "file" then abs = candidate end
        end
    end
    if abs:sub(1, 1) ~= "/" then return path end
    local ok, FontList = pcall(require, "fontlist")
    if not ok or not FontList.getFontList then return abs end
    FontList:getFontList()
    for _idx, item in ipairs(FontList.fontlist or {}) do
        if item == abs then return abs end
    end
    table.insert(FontList.fontlist, 1, abs)
    return abs
end

--- 按文件名在已扫到的字体目录里找已存在的文件并登记。
---@param name string 路径或 basename（如 NotoSansCJKsc-Regular.otf）
---@return string|nil
function Card.bundledFont(name)
    if type(name) ~= "string" or name == "" then return nil end
    local resolved = Card.registerFont(name)
    if type(resolved) == "string" and resolved:sub(1, 1) == "/" then return resolved end
    local base = name:match("[^/]+$") or name
    for _idx, dir in ipairs(Card.fontDirs()) do
        local found = Card.registerFont(dir .. "/" .. base)
        if type(found) == "string" and found:sub(1, 1) == "/" then return found end
    end
    return nil
end

--- Font:getFace 能否打开该文件（含可选 TTC faceindex）。
---@param path string
---@param faceindex number|nil
---@return boolean
function Card.fontWorks(path, faceindex)
    return require("ui/font"):getFace(path, 16, faceindex) ~= nil
end

--- 打开一个可用字体：先试指定文件（TTC 会选面，失败再试默认面），再试自带 Noto Sans CJK SC，
--- 仍打不开时（allow_cfont）回退 cfont。粗体文件失败时不回退 cfont，交给调用方改走合成粗体。
---@param path string|nil
---@param bold boolean|nil
---@param allow_cfont boolean|nil
---@return string|nil, number|nil
function Card.usableFont(path, bold, allow_cfont)
    local function try(candidate)
        if type(candidate) ~= "string" or candidate == "" then return nil end
        candidate = Card.registerFont(candidate)
        local index = Card.ttcFaceIndex(candidate, bold)
        if Card.fontWorks(candidate, index) then return candidate, index end
        if index ~= nil and Card.fontWorks(candidate, nil) then return candidate, nil end
        return nil
    end
    local found, index = try(path)
    if found then return found, index end
    found, index = try(Card.bundledFont("NotoSansCJKsc-Regular.otf"))
    if found then return found, index end
    if allow_cfont then return "cfont", nil end
    return nil
end

--- TTC 往往第一面不是简体 Regular（Songti.ttc 第一面是 Black）。挑简体 Regular / Bold 的 faceindex。
---@param path string|nil
---@param bold boolean|nil
---@return number|nil
function Card.ttcFaceIndex(path, bold)
    if type(path) ~= "string" or not path:lower():match("%.ttc$") then return nil end
    local ok, FT = pcall(require, "ffi/freetype")
    if not ok or not FT.getFaceCount then return nil end
    local n = FT.getFaceCount(path)
    if not n or n <= 0 then return nil end
    local best_i, best_score
    for i = 0, n - 1 do
        local opened, ftsize = pcall(FT.newFaceSize, path, nil, i)
        if opened and ftsize then
            local family, style = "", ""
            pcall(function()
                if ftsize.getInfo then
                    local info = ftsize:getInfo()
                    family = tostring(info.family or info.name or "")
                    style = tostring(info.style or "")
                end
                if family == "" and ftsize.face then
                    family = tostring(ftsize.face.family_name or "")
                    style = tostring(ftsize.face.style_name or "")
                end
            end)
            if ftsize.done then ftsize:done() end
            local name = family .. " " .. style
            local score = 0
            if name:find("SC", 1, true) or name:find("CN", 1, true) or name:find("GB", 1, true) or name:find("简") then
                score = score + 20
            end
            if bold then
                if name:find("Bold", 1, true) or name:find("Heavy", 1, true) or name:find("粗") then
                    score = score + 10
                elseif name:find("Black", 1, true) then
                    score = score + 4
                end
            else
                if name:find("Regular", 1, true) or name:find("标准") then
                    score = score + 10
                elseif name:find("Medium", 1, true) then
                    score = score + 6
                end
                if name:find("Light", 1, true) or name:find("Bold", 1, true) or name:find("Black", 1, true) or name:find("Italic", 1, true) then
                    score = score - 20
                end
            end
            if not best_score or score > best_score then
                best_score, best_i = score, i
            end
        end
    end
    if best_score and best_score > 0 then return best_i end
    return nil
end

--- 在字体目录里按家族挑完整 CJK。
---@param family string|nil
---@return string regular, string|nil bold
function Card.fontFace(family)
    family = family or "song"
    Card._faces = Card._faces or {}
    if Card._faces[family] then
        return Card._faces[family][1], Card._faces[family][2]
    end
    if not Card._font_files then
        local lfs = require("libs/libkoreader-lfs")
        local found = {}
        for _idx, dir in ipairs(Card.fontDirs()) do
            for name in lfs.dir(dir) do
                if name:match("%.[ot]t[fc]$") then
                    found[#found + 1] = { path = dir .. "/" .. name, name = name }
                end
            end
        end
        Card._font_files = found
    end
    local regular, bold = Card.chooseFont(Card._font_files, family)
    local faceindex, bold_faceindex
    regular, faceindex = Card.usableFont(regular, false, true)
    if bold then
        bold, bold_faceindex = Card.usableFont(bold, true, false)
    end
    Card._faces[family] = { regular, bold, faceindex, bold_faceindex }
    return regular, bold
end

local HEAVY = { "Black", "Heavy", "Bold", "SemiBold" }

--- 同族粗体：文件名里的 Regular/Medium/Light 换成 Black/Heavy/Bold，或在扩展名前补 -Bold。
---@param path string
---@return string|nil
function Card.boldSibling(path)
    local dir, base, ext = path:match("^(.-)([^/]+)(%.[^.]+)$")
    if not base then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local function exists(cand)
        return lfs.attributes(cand, "mode") == "file"
    end
    for _idx, heavy in ipairs(HEAVY) do
        for _i, light in ipairs({ "Regular", "Medium", "Light", "Normal", "Book" }) do
            if base:find(light, 1, true) then
                local cand = dir .. base:gsub(light, heavy, 1) .. ext
                if exists(cand) then return cand end
            end
        end
        local cand = dir .. base .. "-" .. heavy .. ext
        if exists(cand) then return cand end
    end
    return nil
end

--- 字体选择器里的 id → 可用正/粗体路径。文件已不在或打不开时返回 nil，调用方回落自动字体。
---@param id string
---@return string|nil regular, string|nil bold, number|nil faceindex, number|nil bold_faceindex
function Card.facesForId(id)
    if type(id) ~= "string" or id == "" then return nil end
    local path, err = require("ui.fonts").pathForId(id)
    if not path then
        require("utils.log").warn("book share font missing, fallback auto", id, err)
        return nil
    end
    local regular, faceindex = Card.usableFont(path, false, true)
    if not regular then
        require("utils.log").warn("book share font missing, fallback auto", id, path)
        return nil
    end
    local bold, bold_faceindex
    local sibling = Card.boldSibling(path)
    if sibling then
        bold, bold_faceindex = Card.usableFont(sibling, true, false)
    end
    return regular, bold, faceindex, bold_faceindex
end

--- 插件自带 logo.png。
---@return string
function Card.logoPath()
    local src = debug.getinfo(1, "S").source
    local root = src:match("^@(.+)/features/share/[^/]+$")
    if root then
        local path = root .. "/logo.png"
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(path, "mode") == "file" then return path end
    end
    return "logo.png"
end

--- 插画文件路径（插件 features/share/art/）。
---@param id string
---@return string|nil
function Card.artPath(id)
    local entry = Card.SCENIC[id] or Card.VISTA[id]
    if not entry then return nil end
    local src = debug.getinfo(1, "S").source
    local root = src:match("^@(.+)/features/share/[^/]+$")
    if root then
        local path = root .. "/features/share/art/" .. entry.file
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(path, "mode") == "file" then return path end
        return path
    end
    return "features/share/art/" .. entry.file
end

---@return string
function Card.pluginRoot()
    local src = debug.getinfo(1, "S").source
    return src:match("^@(.+)/features/share/[^/]+$")
end

---@return number
function Card.canvasWidth()
    return Card.OUTPUT_WIDTH
end

--- 读取像素亮度；Color8 用 .a，RGB 走 getColor8，避免把 cdata 误读成留白。
---@param px any
---@return number
local function pixelLuma(px)
    if type(px) == "number" then return px end
    if type(px) ~= "table" and type(px) ~= "cdata" and type(px) ~= "userdata" then
        return 255
    end
    if px.getColor8 then
        local ok, c8 = pcall(function() return px:getColor8() end)
        if ok and c8 and type(c8.a) == "number" then return c8.a end
    end
    if type(px.a) == "number" then return px.a end
    if type(px.l) == "number" then return px.l end
    if type(px.r) == "number" then
        return math.floor(0.299 * px.r + 0.587 * (px.g or px.r) + 0.114 * (px.b or px.r) + 0.5)
    end
    return 255
end

--- 量出「」字模左侧留白，好把墨迹贴到卡片左缘（中文引号左侧空白很大）。
---@param face string
---@param size number 交给 Font:getFace 的字号
---@return number
function Card.quoteBearing(face, size, faceindex)
    local fallback = math.floor((size or 24) * 0.6 + 0.5)
    local ok, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
    if not ok then return fallback end
    local Render = require("features.lockscreen.render")
    local opened = Render.getFace(face, size, faceindex)
    if not opened then return fallback end
    local widget = TextBoxWidget:new{
        text = Card.QUOTE_MARK,
        face = opened,
        width = math.max(32, math.ceil((size or 24) * 3)),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }
    -- getSize 会触发绘制，保证能读到 _bb。
    if widget.getSize then pcall(function() widget:getSize() end) end
    local bearing = fallback
    local measured_ok, measured = pcall(function()
        local bb = widget._bb
        if not (bb and bb.getWidth and bb.getHeight) then return fallback end
        local w, h = bb:getWidth(), bb:getHeight()
        for x = 0, w - 1 do
            for y = 0, h - 1 do
                if pixelLuma(bb:getPixel(x, y)) < 240 then return x end
            end
        end
        return fallback
    end)
    if measured_ok and type(measured) == "number" then bearing = measured end
    if widget.free then widget:free() end
    return bearing
end

---@class ShareCardMetrics
---@field dpi number Font:getFace 会再乘的 DPI 系数；测试里取 1
---@field face string
---@field bold_face string|nil
---@field faceindex number|nil
---@field bold_faceindex number|nil
---@field logo string
---@field measure fun(text: string, width: number, size: number, bold: boolean|nil, opts: table|nil): number
---@field measure_width fun(text: string, size: number, bold: boolean|nil): number
---@field bearing fun(size: number): number

---@param opts table|nil
---@return ShareCardMetrics
function Card.defaultMetrics(opts)
    local Screen = Device.screen
    local dpi = Screen.scaleBySize and (Screen:scaleBySize(1000) / 1000) or 1
    if dpi <= 0 then dpi = 1 end
    local face, bold_face, faceindex, bold_faceindex
    if opts and opts.font_id then
        face, bold_face, faceindex, bold_faceindex = Card.facesForId(opts.font_id)
    end
    if not face then
        local family = (opts and opts.font) or "song"
        face, bold_face = Card.fontFace(family)
        local faces = (Card._faces and Card._faces[family]) or {}
        faceindex, bold_faceindex = faces[3], faces[4]
    end
    local Render = require("features.lockscreen.render")
    return {
        dpi = dpi,
        face = face,
        bold_face = bold_face,
        faceindex = faceindex,
        bold_faceindex = bold_faceindex,
        logo = Card.logoPath(),
        measure = function(text, width, size, bold, meas_opts)
            meas_opts = meas_opts or {}
            if meas_opts.faceindex == nil then
                meas_opts.faceindex = (bold and bold_faceindex) or faceindex
            end
            return Render.measureText(text, width, size, bold, meas_opts)
        end,
        measure_width = function(text, size, bold)
            local RenderText = require("ui/rendertext")
            local Render = require("features.lockscreen.render")
            local use = (bold and bold_face) or face
            local index = (bold and bold_faceindex) or faceindex
            local opened = Render.getFace(use, size, index)
            if not opened then return 0 end
            local dimen = RenderText:sizeUtf8Text(0, 100000, opened, text or "", true, bold == true and not bold_face)
            return dimen.x
        end,
        bearing = function(size)
            return Card.quoteBearing(face, size, faceindex)
        end,
    }
end

--- 单行在给定宽度内截断并加省略号。
---@return string
local function fitLine(text, width, size, bold, metrics)
    if text == "" or metrics.measure_width(text, size, bold) <= width then return text end
    local low, high, fitted = 0, #text, "…"
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = Text.truncateUtf8(text, mid) .. "…"
        if metrics.measure_width(candidate, size, bold) <= width then
            fitted, low = candidate, mid + 1
        else
            high = mid - 1
        end
    end
    return fitted
end

--- 正文先降字号，最小字号仍超高再按 UTF-8 截断。
---@return string text, number size, number height
local function fitQuote(text, width, size, min_size, max_h, bold, leading, face, metrics)
    local opts = { face = face, justified = true, line_height = leading }
    local height = metrics.measure(text, width, size, bold, opts)
    while height > max_h and size > min_size do
        size = size - 1
        height = metrics.measure(text, width, size, bold, opts)
    end
    if height <= max_h then return text, size, height end
    local low, high, fitted = 0, #text, "…"
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = Text.truncateUtf8(text, mid) .. "…"
        local h = metrics.measure(candidate, width, size, bold, opts)
        if h <= max_h then
            fitted, height, low = candidate, h, mid + 1
        else
            high = mid - 1
        end
    end
    return fitted, size, height
end

--- 页脚：左封面+书名，右 logo+月读。cover_hidden 时不算封面占位（静影封面已作背景）。
local function buildFooter(ctx)
    local px, fontSize, pal, spec, metrics, payload, width = ctx.px, ctx.fontSize, ctx.pal, ctx.spec, ctx.metrics, ctx.payload, ctx.width
    local pad_x = ctx.pad_x
    local show_logo = ctx.show_logo
    local has_cover = ctx.has_cover and not ctx.cover_hidden
    local cover_w, cover_h = px(spec.cover_w), px(spec.cover_h)
    local logo_s = px(spec.logo)
    local brand = Card.BRAND
    local brand_size = fontSize(spec.brand_size)
    local brand_w = show_logo and metrics.measure_width(brand, brand_size, spec.brand_bold) or 0
    local brand_col = show_logo and (logo_s + px(8) + math.ceil(brand_w)) or 0
    local left_right_gap = show_logo and px(16) or 0
    local text_w = width - pad_x * 2
    local left_w = text_w - brand_col - left_right_gap
    local title_text = Card.bookTitle(payload.title)
    local byline_text = Card.byline(payload.authors, payload.chapter)
    local title_size = fontSize(spec.title_size)
    local byline_size = fontSize(spec.byline_size)
    local text_left = pad_x
    local cover
    if has_cover then
        cover = { path = payload.cover, w = cover_w, h = cover_h }
        text_left = pad_x + cover_w + px(10)
        left_w = left_w - cover_w - px(10)
    end
    left_w = math.max(px(40), left_w)
    title_text = fitLine(title_text, left_w, title_size, true, metrics)
    byline_text = fitLine(byline_text, left_w, byline_size, false, metrics)
    local face = metrics.face
    local faceindex = metrics.faceindex
    local title_h = title_text ~= "" and metrics.measure(title_text, left_w, title_size, true, {
        face = face, line_height = 0.2,
    }) or 0
    local byline_h = byline_text ~= "" and metrics.measure(byline_text, left_w, byline_size, false, {
        face = face, line_height = 0.2,
    }) or 0
    local meta_h = title_h + (title_h > 0 and byline_h > 0 and px(3) or 0) + byline_h
    local foot_content_h = math.max(has_cover and cover_h or 0, meta_h, show_logo and logo_s or 0)
    local foot_ink = ctx.foot_ink or pal.ink
    local foot_muted = ctx.foot_muted or pal.muted
    return {
        cover = cover,
        title_text = title_text,
        byline_text = byline_text,
        title_h = title_h,
        byline_h = byline_h,
        meta_h = meta_h,
        text_left = text_left,
        left_w = left_w,
        title_size = title_size,
        byline_size = byline_size,
        logo_s = logo_s,
        brand = brand,
        brand_w = brand_w,
        brand_col = brand_col,
        brand_size = brand_size,
        foot_content_h = foot_content_h,
        show_logo = show_logo,
        foot_ink = foot_ink,
        foot_muted = foot_muted,
        face = face,
        faceindex = faceindex,
    }
end

local function placeFooter(layout, foot, pad_x, width, foot_y, metrics)
    if foot.cover then
        layout.cover = {
            path = foot.cover.path,
            x = pad_x,
            y = foot_y,
            w = foot.cover.w,
            h = foot.cover.h,
        }
    end
    if foot.title_text ~= "" then
        layout.title = {
            text = foot.title_text,
            x = foot.text_left,
            y = foot_y + math.max(0, math.floor((foot.foot_content_h - foot.meta_h) / 2)),
            width = foot.left_w,
            size = foot.title_size,
            bold = true,
            color = foot.foot_ink,
            face = foot.face,
            faceindex = foot.faceindex,
        }
    end
    if foot.byline_text ~= "" then
        layout.byline = {
            text = foot.byline_text,
            x = foot.text_left,
            y = foot_y + math.max(0, math.floor((foot.foot_content_h - foot.meta_h) / 2))
                + foot.title_h + (foot.title_h > 0 and layout.unit_gap or 0),
            width = foot.left_w,
            size = foot.byline_size,
            bold = false,
            color = foot.foot_muted,
            face = foot.face,
            faceindex = foot.faceindex,
        }
    end
    if foot.show_logo then
        layout.logo = {
            path = metrics.logo,
            x = width - pad_x - foot.brand_col,
            y = foot_y + math.max(0, math.floor((foot.foot_content_h - foot.logo_s) / 2)),
            size = foot.logo_s,
        }
        layout.brand = {
            text = foot.brand,
            x = width - pad_x - math.ceil(foot.brand_w),
            y = foot_y + math.max(0, math.floor((foot.foot_content_h - foot.logo_s) / 2)
                + (foot.logo_s - math.ceil(foot.brand_size * metrics.dpi * 1.2)) / 2),
            width = math.ceil(foot.brand_w) + 2,
            size = foot.brand_size,
            bold = layout.brand_bold,
            color = layout.brand_bold and foot.foot_ink or foot.foot_muted,
            face = foot.face,
            faceindex = foot.faceindex,
        }
    end
end

--- 计算一张卡片的几何（物理像素）。测试可传入 metrics 避免依赖真实字体。
---@param style string
---@param payload { text: string, title?: string, authors?: string, chapter?: string, cover?: string|nil }
---@param width number|nil
---@param metrics ShareCardMetrics|nil
---@param opts table|nil
---@return table
function Card.layout(style, payload, width, metrics, opts)
    payload = payload or {}
    opts = opts or {}
    style, opts.swatch = Card.migrate(style, opts.swatch)
    opts.theme = style
    opts = Card.normalize(opts)
    style = opts.theme or style
    assert(Card.isStyle(style), "unknown share style")
    metrics = metrics or Card.defaultMetrics(opts)
    width = math.floor(tonumber(width) or Card.canvasWidth())
    local unit = width / Card.DESIGN_WIDTH
    local function px(n) return math.max(0, math.floor(n * unit + 0.5)) end
    local function fontSize(css) return css * unit / metrics.dpi end
    local pal = Card.palette(style, opts)
    local spec = pal.spec
    local face = metrics.face
    local faceindex = metrics.faceindex
    local pad_x = px(style == "letter" and (spec.pad_left or spec.pad_x) or spec.pad_x)
    local pad_right = px(spec.pad_x)
    local pad_top = px(spec.pad_top)
    local pad_bottom = px(spec.pad_bottom)
    -- 外框贴着卡片底边距；页脚如果还要避开色带或内框，另加 content_bottom。
    local frame_pad_bottom = pad_bottom
    local band_h = style == "brocade" and px(spec.band_h) or 0
    -- 锦书页脚要落在底部色带之上，底边距含色带高度。
    if band_h > 0 then
        pad_bottom = pad_bottom + band_h
    end
    -- 经典内框底部还要给双线框留出内边距，避免页脚压线。
    if style == "classic" then
        pad_bottom = pad_bottom + px(spec.inner_pad_bottom) + px(3)
    end
    local banner_h = pal.banner and px(spec.banner_h or 8) or 0
    local text_w = width - pad_x - (style == "letter" and pad_right or pad_x)
    if style == "classic" then
        -- 内框再缩一圈
        text_w = width - px(spec.pad_x) * 2 - px(spec.inner_pad_x) * 2
    end
    if style == "ink" then
        text_w = width - pad_x * 2 - px(spec.bar_gap)
    end
    local quote_size = fontSize(spec.quote_size)
    local min_quote = fontSize(14)
    local leading = spec.quote_leading
    if style == "letter" then
        -- 行高跟横格 32px 对齐，TextBox 的 line_height 是「额外行距 / 字号」。
        local rule_px = px(spec.rule)
        leading = math.max(0, (rule_px - quote_size * metrics.dpi) / math.max(quote_size * metrics.dpi, 1))
    end
    -- 画境、远山、静影等主题用 min_h 保持统一画布高度，短摘文不裁切插画。
    local min_h = px(spec.min_h or 0)
    local max_quote_h
    if min_h > 0 then
        max_quote_h = math.max(px(80), min_h - px(180))
    else
        max_quote_h = math.floor(width * 1.45)
    end
    local quote_text = Text.trim(tostring(payload.text or ""))
    local body, q_size, quote_h = fitQuote(
        quote_text, text_w, quote_size, min_quote, max_quote_h, spec.quote_bold, leading, face, metrics)

    local has_cover = type(payload.cover) == "string" and payload.cover ~= ""
    local foot_ctx = {
        px = px, fontSize = fontSize, pal = pal, spec = spec, metrics = metrics,
        payload = payload, width = width, pad_x = (style == "vista" or style == "scenic") and px(spec.foot_pad_x or 20) or pad_x,
        show_logo = opts.show_logo, has_cover = has_cover,
        cover_hidden = style == "cinema" and has_cover,
    }
    if pal.foot_light then
        foot_ctx.foot_ink = Card.color(0xF4EEE4, 0xF0)
        foot_ctx.foot_muted = Card.color(0xD5CBBD, 0xC0)
    end
    local foot = buildFooter(foot_ctx)
    local foot_gap = px(spec.foot_gap or 28)
    local rule_pad = px(spec.rule_pad or 16)
    -- 页脚上方的分割线占 rule_pad（线到页脚内容），有的主题没有分割线（经典、手札、画境、远山）。
    local has_rule = (style ~= "classic" and style ~= "letter" and style ~= "scenic" and style ~= "vista")
    local foot_head = (has_rule and (foot_gap + rule_pad) or foot_gap) + foot.foot_content_h + pad_bottom

    -- 各主题「摘文之上」的高度（顶条、日历头、行款、引号留白、锦书色带、远山风景）。
    local head_h = banner_h + pad_top
    local cal, running, art_h
    local running_size = fontSize(13)
    if style == "calendar" then
        cal = Card.calendarDate(opts.now)
        head_h = banner_h + pad_top
            + fontSize(12) * metrics.dpi * 1.3 -- cal-meta
            + px(2)
            + fontSize(spec.day_size) * metrics.dpi * 0.9
            + px(8) + 1 + px(16) -- rule + 下间距
    elseif style == "classic" then
        running = Card.stripTitleMarks(payload.title)
        local run_w = width - px(spec.pad_x) * 2
        if running ~= "" then
            running = fitLine(running, run_w, running_size, false, metrics)
        end
        head_h = banner_h + pad_top + (running ~= "" and (running_size * metrics.dpi * 1.3 + px(12)) or px(2))
            + px(spec.inner_pad_top)
    elseif style == "ink" then
        head_h = banner_h + pad_top + px(4)
    elseif style == "letter" then
        head_h = banner_h + pad_top + px(spec.quote_pad_top)
    elseif style == "brocade" then
        head_h = band_h + px(spec.pad_top)
    elseif style == "paper" then
        -- 与既有实现对齐：正文 y = 上边距 + quote_top（44 CSS），引号贴左缘 8 CSS。
        head_h = banner_h + pad_top + px(spec.quote_top)
    elseif style == "scenic" then
        local conf = Card.SCENIC[opts.art] or Card.SCENIC.sunset
        if conf.quote == "high" then
            head_h = px(44)
        else
            head_h = pad_top
        end
    elseif style == "vista" then
        art_h = px(spec.art_h)
        head_h = art_h + pad_top
    elseif style == "cinema" then
        head_h = pad_top
    end

    local content_h = head_h + quote_h + foot_head
    local height = math.max(content_h, min_h)
    -- 有最小高度时，把多余空白分给摘文区，页脚贴底。
    local extra = height - content_h
    local quote_y = head_h
    local align = "start"
    if style == "cinema" then
        align = "end"
    elseif style == "scenic" then
        local conf = Card.SCENIC[opts.art] or Card.SCENIC.sunset
        align = conf.quote -- mid/high/low
        if align == "high" then align = "start" end
        if align == "low" then align = "end" end
        if align == "mid" then align = "center" end
    elseif spec.min_h and extra > 0 then
        align = "center"
    end
    if extra > 0 then
        if align == "center" then
            quote_y = head_h + math.floor(extra / 2)
        elseif align == "end" then
            quote_y = head_h + extra
        end
    end
    if style == "scenic" and (Card.SCENIC[opts.art] or Card.SCENIC.sunset).quote == "low" then
        -- 窗夜：摘文贴近页脚，只留 4 CSS 的下边距。
        quote_y = height - foot_head - quote_h + math.max(0, foot_gap - px(4))
        quote_y = math.max(head_h, quote_y)
    end

    local quote_x = pad_x
    if style == "ink" then quote_x = pad_x + px(spec.bar_gap) end
    if style == "classic" then quote_x = px(spec.pad_x) + px(spec.inner_pad_x) end
    if style == "scenic" or style == "vista" then
        quote_x = px(style == "vista" and spec.pad_x or spec.pad_x)
    end

    local rule_y, foot_y
    if has_rule then
        rule_y = height - pad_bottom - foot.foot_content_h - rule_pad
        foot_y = rule_y + rule_pad
    else
        local foot_pad = (style == "scenic" or style == "vista") and px(spec.foot_pad_top or 8) or 0
        foot_y = height - pad_bottom - foot.foot_content_h
        if style == "scenic" then
            -- 页脚自带上内边距，贴底。
            foot_y = height - pad_bottom - foot.foot_content_h
        end
        if foot_pad > 0 and style == "vista" then
            -- 远山页脚在纸面上，上边距已含在 foot_gap 里。
        end
    end

    local layout = {
        style = style,
        width = width,
        height = height,
        bg = pal.bg,
        ink = pal.ink,
        muted = pal.muted,
        line = pal.line,
        face = face,
        bold_face = metrics.bold_face,
        brand_bold = spec.brand_bold,
        unit_gap = px(3),
        opts = opts,
        pal = pal,
        has_cover = has_cover,
        art = opts.art,
        art_path = opts.art_path or (opts.art and Card.artPath(opts.art) or nil),
        calendar = cal,
        running = (running and running ~= "") and running or nil,
        banner = pal.banner and { height = banner_h, colors = pal.banner } or nil,
        quote = {
            text = body,
            x = quote_x,
            y = quote_y,
            width = text_w,
            size = q_size,
            bold = spec.quote_bold,
            line_height = leading,
            justified = true,
            color = pal.ink,
            face = face,
            faceindex = faceindex,
        },
    }

    if has_rule then
        local rule_x, rule_w = pad_x, width - pad_x * 2
        layout.rule = { x = rule_x, y = rule_y, width = rule_w, color = pal.line }
    end

    if style == "paper" then
        local m_size = fontSize(spec.mark_size)
        local bearing = metrics.bearing(m_size)
        local ink_x = px(8)
        local mark_top = banner_h + pad_top + px(2)
        layout.mark = {
            text = Card.QUOTE_MARK,
            x = ink_x - bearing,
            y = mark_top,
            size = m_size,
            color = pal.mark,
            bearing = bearing,
            face = face,
            faceindex = faceindex,
        }
    elseif style == "ink" then
        layout.bar = {
            x = pad_x,
            y = quote_y + px(8),
            width = px(2),
            height = math.max(px(24), quote_h - px(16)),
            color = pal.ink,
        }
        local m_size = fontSize(spec.mark_size)
        local bearing = metrics.bearing(m_size)
        layout.watermark = {
            text = Card.QUOTE_MARK,
            x = width - pad_x - px(8) - math.floor(m_size * metrics.dpi * 0.55) - bearing,
            y = banner_h + pad_top - px(36),
            size = m_size,
            color = pal.mark,
            face = face,
            faceindex = faceindex,
        }
    end

    if style == "classic" then
        local box_x = px(spec.pad_x)
        local box_w = width - box_x * 2
        local box_y = banner_h + pad_top + (layout.running and (running_size * metrics.dpi * 1.3 + px(12)) or px(2))
        local box_h = height - box_y - frame_pad_bottom
        layout.frame = { x = box_x, y = box_y, width = box_w, height = box_h, color = pal.line, inset = px(3) }
        if layout.running then
            layout.running_block = {
                text = layout.running,
                x = box_x,
                y = banner_h + pad_top,
                width = box_w,
                size = running_size,
                color = pal.muted,
                face = face,
                faceindex = faceindex,
                align = "center",
            }
        end
    end

    if style == "calendar" and cal then
        local day_css = spec.day_size
        layout.cal_meta = {
            text = cal.meta,
            x = pad_x,
            y = banner_h + pad_top,
            width = text_w,
            size = fontSize(12),
            color = pal.muted,
            face = face,
            faceindex = faceindex,
        }
        layout.cal_day = {
            text = cal.day,
            x = pad_x,
            y = banner_h + pad_top + fontSize(12) * metrics.dpi * 1.3 + px(2),
            width = math.floor(text_w * 0.62),
            size = fontSize(day_css),
            bold = true,
            color = pal.mark,
            face = face,
            faceindex = faceindex,
        }
        layout.cal_week = {
            text = cal.week,
            x = pad_x,
            y = layout.cal_day.y + fontSize(day_css) * metrics.dpi * 0.9 - fontSize(14) * metrics.dpi * 1.2,
            width = text_w,
            size = fontSize(14),
            color = pal.ink,
            face = face,
            faceindex = faceindex,
            align = "right",
        }
        layout.cal_rule = {
            x = pad_x,
            y = layout.cal_day.y + fontSize(day_css) * metrics.dpi * 0.9 + px(8),
            width = text_w,
            color = pal.line,
        }
    end

    if style == "letter" then
        layout.lines = {
            bg = pal.bg,
            margin_x = px(20),
            margin_color = pal.margin_line,
            rule = px(spec.rule),
            rule_color = pal.rule_color,
            -- 横格画到页脚上沿，由页脚底色盖住穿过页脚的线。
            foot_top = foot_y,
        }
    end

    if style == "brocade" then
        layout.bands = {
            height = px(spec.band_h),
            color = pal.band,
            gold = pal.gold,
        }
    end

    if style == "cinema" then
        layout.media = {
            cover = has_cover and payload.cover or nil,
            zoom = 1.12,
            overlay = pal.overlay,
        }
    end

    if style == "scenic" then
        layout.scenic = {
            path = layout.art_path,
            foot_light = pal.foot_light,
            foot_top = foot_y - px(spec.foot_pad_top or 14),
        }
    end

    if style == "vista" then
        layout.vista = {
            path = layout.art_path,
            height = art_h or px(spec.art_h),
            anchor_y = 0.42,
        }
        -- 远山底部纸色已是底色，风景只占顶部。
    end

    local foot_pad_x = (style == "scenic" or style == "vista") and px(spec.foot_pad_x or 20)
        or (style == "classic" and (px(spec.pad_x) + px(4)) or pad_x)
    placeFooter(layout, foot, foot_pad_x, width, foot_y, metrics)
    -- PNG 画布宽高必须是整数；日历等主题用了 0.9 倍行距，会留下小数。
    layout.width = math.floor((layout.width or 0) + 0.5)
    layout.height = math.ceil(layout.height or 0)
    return layout
end

--- 把 layout 转成锁屏渲染器能画的块。
---@param layout table
---@return table[]
function Card.blocks(layout)
    local blocks = {}
    local style = layout.style

    if layout.media then
        if layout.media.cover then
            blocks[#blocks + 1] = {
                kind = "image", file = layout.media.cover, x = 0, y = 0,
                width = layout.width, height = layout.height, cover = true,
                blur = true, zoom = layout.media.zoom or 1.12, anchor_y = 0.5,
            }
        else
            -- 没有封面时用深色径向近似：上下两截垂直渐变。
            blocks[#blocks + 1] = {
                kind = "vgradient", x = 0, y = 0, width = layout.width, height = layout.height,
                colors = { Card.color(0x3A332C, 0x30), Card.color(0x0C0B0A, 0x0A) },
            }
        end
        local ov = layout.media.overlay or CINEMA_OVERLAY.default
        blocks[#blocks + 1] = {
            kind = "vgradient", x = 0, y = 0, width = layout.width, height = layout.height,
            colors = { Card.color(ov[1], 0x10), Card.color(ov[3], 0x08) },
            blend = true, alpha_from = (ov[2] or 0x42) / 255, alpha_to = (ov[4] or 0x84) / 255,
        }
    end

    if layout.scenic and layout.scenic.path then
        blocks[#blocks + 1] = {
            kind = "image", file = layout.scenic.path, x = 0, y = 0,
            width = layout.width, height = layout.height, cover = true, anchor_y = 0.5,
        }
        if layout.scenic.foot_light then
            local top = layout.scenic.foot_top or math.floor(layout.height * 0.75)
            blocks[#blocks + 1] = {
                kind = "vgradient", x = 0, y = top, width = layout.width,
                height = layout.height - top,
                colors = { Card.color(0x100A06, 0x10), Card.color(0x100A06, 0x10) },
                blend = true, alpha_from = 0, alpha_to = 0.62,
            }
        end
    end

    if layout.vista and layout.vista.path then
        blocks[#blocks + 1] = {
            kind = "image", file = layout.vista.path, x = 0, y = 0,
            width = layout.width, height = layout.vista.height, cover = true,
            anchor_y = layout.vista.anchor_y or 0.42,
        }
    end

    if layout.bands then
        local h = layout.bands.height
        local function band(y)
            blocks[#blocks + 1] = {
                kind = "panel", x = 0, y = y, width = layout.width, height = h,
                color = layout.bands.color, radius = 0,
            }
            -- 金线贴色带上下缘，代替卷草纹样。
            blocks[#blocks + 1] = {
                kind = "rule", x = 0, y = y + math.max(1, math.floor(h * 0.12)),
                width = layout.width, height = 1, color = layout.bands.gold,
            }
            blocks[#blocks + 1] = {
                kind = "rule", x = 0, y = y + h - 1 - math.max(1, math.floor(h * 0.12)),
                width = layout.width, height = 1, color = layout.bands.gold,
            }
        end
        band(0)
        band(layout.height - h)
    end

    if layout.lines then
        local L = layout.lines
        if L.margin_color then
            blocks[#blocks + 1] = {
                kind = "rule", x = L.margin_x, y = 0, width = 1, height = layout.height, color = L.margin_color,
            }
        end
        if L.rule and L.rule > 0 and L.rule_color then
            local foot = L.foot_top or layout.height
            local y = L.rule
            local last = nil
            while y < foot do
                blocks[#blocks + 1] = {
                    kind = "rule", x = 0, y = y, width = layout.width, height = 1, color = L.rule_color,
                }
                last = y
                y = y + L.rule
            end
            -- 最后一根横格落在页脚上沿，避免行距对齐后留下一块空白。
            if last ~= foot and foot > 0 then
                blocks[#blocks + 1] = {
                    kind = "rule", x = 0, y = foot, width = layout.width, height = 1, color = L.rule_color,
                }
            end
        end
        -- 页脚铺一层底色，盖住横格。
        if L.foot_top and L.bg then
            blocks[#blocks + 1] = {
                kind = "panel", x = 0, y = L.foot_top, width = layout.width,
                height = layout.height - L.foot_top, color = L.bg, radius = 0,
            }
        end
    end

    if layout.banner then
        local h = layout.banner.height
        local colors = layout.banner.colors
        local Screen = Device.screen
        -- 彩屏按列插值成平滑渐变；电纸用实心深色细条，保住对比。
        if colors[2] and Screen.isColorEnabled and Screen:isColorEnabled() then
            blocks[#blocks + 1] = {
                kind = "hgradient", x = 0, y = 0, width = layout.width, height = h,
                colors = colors,
            }
        else
            blocks[#blocks + 1] = {
                kind = "panel", x = 0, y = 0, width = layout.width, height = h,
                color = colors[1], radius = 0,
            }
        end
    end

    if layout.frame then
        local f = layout.frame
        blocks[#blocks + 1] = {
            kind = "border", x = f.x, y = f.y, width = f.width, height = f.height,
            border = 1, color = f.color, radius = 0,
        }
        local inset = f.inset or 3
        blocks[#blocks + 1] = {
            kind = "border", x = f.x + inset, y = f.y + inset,
            width = f.width - inset * 2, height = f.height - inset * 2,
            border = 1, color = f.color, radius = 0,
        }
    end

    if layout.bar then
        local b = layout.bar
        blocks[#blocks + 1] = {
            kind = "panel", x = b.x, y = b.y, width = b.width, height = b.height,
            color = b.color, radius = 0,
        }
    end

    if layout.cal_meta then
        for _idx, key in ipairs({ "cal_meta", "cal_day", "cal_week" }) do
            local t = layout[key]
            blocks[#blocks + 1] = {
                text = t.text, x = t.x, y = t.y, width = t.width, size = t.size,
                bold = t.bold, box = false, color = t.color, face = t.face, faceindex = t.faceindex,
                align = t.align, line_height = (key == "cal_day") and 0.0 or 0.2,
            }
        end
        if layout.cal_rule then
            local r = layout.cal_rule
            blocks[#blocks + 1] = { kind = "rule", x = r.x, y = r.y, width = r.width, height = 1, color = r.color }
        end
    end

    if layout.running_block then
        local t = layout.running_block
        blocks[#blocks + 1] = {
            text = t.text, x = t.x, y = t.y, width = t.width, size = t.size,
            box = false, color = t.color, face = t.face, faceindex = t.faceindex,
            align = t.align or "center", line_height = 0.2,
        }
    end

    if layout.watermark then
        local m = layout.watermark
        local width = math.max(8, math.ceil((m.size or 24) * 3))
        blocks[#blocks + 1] = {
            text = m.text, x = m.x, y = m.y, width = width,
            size = m.size, bold = true, box = false, color = m.color, face = m.face, faceindex = m.faceindex,
        }
    end

    if layout.mark then
        local m = layout.mark
        local width = math.max(8, math.ceil((m.size or 24) * 3))
        -- 透明底画到主画布：允许负 x，由 colorblit 裁掉字模左侧留白，不要自带底色方块。
        blocks[#blocks + 1] = {
            text = m.text, x = m.x, y = m.y, width = width,
            size = m.size, bold = true, box = false, color = m.color, face = m.face, faceindex = m.faceindex,
        }
    end

    local q = layout.quote
    blocks[#blocks + 1] = {
        text = q.text, x = q.x, y = q.y, width = q.width, size = q.size, bold = q.bold,
        box = false, color = q.color, face = q.face, faceindex = q.faceindex, justified = q.justified, line_height = q.line_height,
    }

    if layout.rule then
        blocks[#blocks + 1] = {
            kind = "rule", x = layout.rule.x, y = layout.rule.y, width = layout.rule.width,
            height = 1, color = layout.rule.color,
        }
    end

    if layout.cover then
        local c = layout.cover
        blocks[#blocks + 1] = {
            kind = "image", file = c.path, x = c.x, y = c.y, width = c.w, height = c.h, scale_factor = 0,
        }
    end
    if layout.title then
        local t = layout.title
        blocks[#blocks + 1] = {
            text = t.text, x = t.x, y = t.y, width = t.width, size = t.size, bold = t.bold,
            box = false, color = t.color, face = t.face, faceindex = t.faceindex, line_height = 0.2,
        }
    end
    if layout.byline then
        local b = layout.byline
        blocks[#blocks + 1] = {
            text = b.text, x = b.x, y = b.y, width = b.width, size = b.size, bold = false,
            box = false, color = b.color, face = b.face, faceindex = b.faceindex, line_height = 0.2,
        }
    end
    if layout.logo then
        local l = layout.logo
        blocks[#blocks + 1] = {
            kind = "image", file = l.path, x = l.x, y = l.y, width = l.size, height = l.size,
            scale_factor = 0, alpha = true, circle = true,
        }
    end
    if layout.brand then
        local b = layout.brand
        blocks[#blocks + 1] = {
            text = b.text, x = b.x, y = b.y, width = b.width, size = b.size, bold = b.bold,
            box = false, color = b.color, face = b.face, faceindex = b.faceindex, line_height = 0.2,
        }
    end
    return blocks
end

--- 收集 layout 里全部会画出来的文案，供测试断言没有 kicker / slogan。
---@param layout table
---@return string[]
function Card.texts(layout)
    local out = {}
    local function add(s)
        if type(s) == "string" and s ~= "" then out[#out + 1] = s end
    end
    if layout.calendar then
        add(layout.calendar.meta)
        add(layout.calendar.day)
        add(layout.calendar.week)
    end
    if layout.running then add(layout.running) end
    if layout.mark then add(layout.mark.text) end
    if layout.watermark then add(layout.watermark.text) end
    if layout.quote then add(layout.quote.text) end
    if layout.title then add(layout.title.text) end
    if layout.byline then add(layout.byline.text) end
    if layout.brand then add(layout.brand.text) end
    return out
end

--- 写出分享 PNG。
---@param style string
---@param payload table
---@param path string
---@param width number|nil
---@param opts table|nil
---@return boolean, any, table|nil
function Card.write(style, payload, path, width, opts)
    local layout = Card.layout(style, payload, width, nil, opts)
    local blocks = Card.blocks(layout)
    local Render = require("features.lockscreen.render")
    local ok, err = Render.writeSize(path, layout.width, layout.height, blocks, layout.bg)
    return ok, err, layout
end

return Card
