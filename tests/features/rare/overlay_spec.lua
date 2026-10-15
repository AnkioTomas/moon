--[[-- features.rare.overlay：注音布局（全屏统一字号、居中、夹边）、点按开查词面板与绘制管线（桩 CRE）。 --]]

local Assert = require("support.assert")

local settings = { rare_enabled = true, rare_level = "rare", rare_size = 0.5, rare_lexicons = { t = true }, rare_built_at = {} }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
local lex
package.preload["features.rare.catalog"] = function()
    return { active = function() return { lex } end }
end
local screen_text = "普通文字龘"
package.preload["reader.context"] = function()
    return { visibleText = function() return screen_text end }
end
package.preload["reader.session"] = function()
    return { current = function() return { identity = { source_id = "local", stable_id = "x", chapter_idx = 1 } } end }
end
package.preload["ui/font"] = function() return { getFace = function(_self, name, size) return { size = size } end } end
local rendered = {}
package.preload["ui/rendertext"] = function()
    return {
        sizeUtf8Text = function(_self, _x, _w, face, text) return { x = #text * face.size / 2 } end,
        renderUtf8Text = function(_self, _bb, x, y, face, text)
            rendered[#rendered + 1] = { x = x, y = y, size = face.size, text = text }
        end,
    }
end
package.preload["apps/reader/readerui"] = function() return {} end
package.preload["ffi/blitbuffer"] = function() return { COLOR_DARK_GRAY = 1 } end

local Overlay = require("features.rare.overlay")

local function measure(text, size) return #text * size / 2 end

-- 管线测试用固定排版尺寸（真机从页面像素量）。行内墨迹 [top, bottom] 相对行顶。
local C = { pitch = 40, top = 7, bottom = 34 }
local realCalibrate = Overlay.calibrate
Overlay.calibrate = function() return C end
Overlay.annInk = function() return { em = 1.3, bottom_em = 0.3 } end

local function geo(size)
    return { size = size, pitch = C.pitch, top = C.top, ann_bottom = math.ceil(0.3 * size), screen_w = 600, measure = measure }
end

do
    -- 统一字号 = min(正文 × 比例, 行间空隙放得下的)，不低于 FLOOR。
    Assert.eq(Overlay.size(30, 0.5), 15)
    Assert.eq(Overlay.size(30, 0.5, 40, 1.3), 15, "空隙够大按比例")
    Assert.eq(Overlay.size(30, 0.5, 12, 1.3), 7, "空隙小按空隙收")
    Assert.eq(Overlay.size(30, 0.5, 3, 1.3), Overlay.FLOOR, "放不下也按下限画")
    Assert.eq(Overlay.size(8, 0.5), Overlay.FLOOR)
end

do
    -- 量页面：pitch 取最矮框（段首高框排除），墨迹取各词合并的最高 / 最低行。
    local dark = {}
    local function ink(x, y) dark[y * 1000 + x] = true end
    for x = 10, 20 do ink(x, 107); ink(x, 125) end     -- 词 1：行顶 100，墨迹 7..25
    for x = 60, 70 do ink(x, 112); ink(x, 134) end     -- 词 2：下伸部到 34
    for x = 200, 210 do ink(x, 300) end                 -- 段首高框里的不算
    local bb = {
        getWidth = function() return 600 end, getHeight = function() return 800 end,
        getPixel = function(_s, x, y) return { getColor8 = function() return { a = dark[y * 1000 + x] and 0 or 255 } end } end,
    }
    local c = realCalibrate(bb, {
        { x = 10, y = 100, w = 20, h = 40 }, { x = 60, y = 100, w = 20, h = 40 }, { x = 200, y = 270, w = 20, h = 60 },
    })
    Assert.eq(c.pitch, 40)
    Assert.eq(c.top, 7)
    Assert.eq(c.bottom, 34)
end

do
    -- 同屏所有注音同一字号；段首高框按底部 pitch 算，与同行普通框同基线。
    local items = Overlay.layout({
        { ann = "dá", key = "龘", box = { x = 100, y = 50, w = 30, h = 40 } },
        { ann = "zhuàng", key = "撞", box = { x = 300, y = 10, w = 10, h = 80 } },
        { ann = "zhuàng", key = "撞", box = { x = 590, y = 90, w = 10, h = 40 } },
    }, geo(7))
    Assert.len(items, 3)
    for _idx, item in ipairs(items) do Assert.eq(item.size, 7) end
    Assert.eq(items[1].x, 109)
    Assert.eq(items[1].y, 54)
    Assert.eq(items[2].y, 54, "段首高框同一行基线")
    Assert.eq(items[3].y, 94)
    Assert.is_true(items[3].x + items[3].w <= 600)
end

do
    -- 不碰上一行（含下伸部，留 MARGIN）也不压本行字：各种行距下按算出的字号布局后检查。
    for pitch = 28, 70 do
        local top, bottom = 3, 26
        local size = Overlay.size(30, 0.5, pitch - (bottom - top + 1), 1.3)
        local ann_bottom = math.ceil(0.3 * size)
        local item = Overlay.layout({ { ann = "a", key = "a", box = { x = 0, y = 200, w = 20, h = pitch } } },
            { size = size, pitch = pitch, top = top, ann_bottom = ann_bottom, screen_w = 600, measure = measure })[1]
        local above_bottom = 200 - pitch + bottom
        local ann_top = item.y - (1.3 - 0.3) * size
        if size > Overlay.FLOOR then
            Assert.is_true(ann_top >= above_bottom + Overlay.MARGIN, "pitch " .. pitch .. " 不碰上一行")
        end
        Assert.is_true(item.y + ann_bottom <= 200 + top, "pitch " .. pitch .. " 不压本行字")
    end
end

do
    -- 同行相邻注音不重叠：词框内能右推就推，推不下跳过后一个；字号不变、纵向不变。
    local items = Overlay.layout({
        { ann = "dá", key = "龘", box = { x = 100, y = 50, w = 30, h = 40 } },
        { ann = "pǔ", key = "普", box = { x = 118, y = 50, w = 34, h = 40 } },
        { ann = "zhuàng", key = "撞", box = { x = 150, y = 50, w = 20, h = 40 } },
        { ann = "pǔ", key = "普", box = { x = 118, y = 120, w = 34, h = 40 } },
    }, geo(15))
    Assert.len(items, 3, "推不下的同行注音被跳过")
    Assert.eq(items[1].x, 103)
    Assert.eq(items[2].x, 127.5, "右推到前一个之后留间距")
    Assert.is_true(items[2].x + items[2].w <= 118 + 34, "仍在本词框内")
    Assert.eq(items[2].y, items[1].y)
    Assert.eq(items[3].key, "普")
    Assert.eq(items[3].x, 123, "不同行不推")
end

local function newUi(matches)
    local finds = 0
    local doc = {
        findText = function(_self, key)
            finds = finds + 1
            return matches[key]
        end,
        getScreenBoxesFromPositions = function(_self, s) return { s } end,
        getCurrentPos = function() return 0 end,
        clearSelection = function() end,
    }
    local ui = { rolling = {}, document = doc, view = { dimen = { w = 600, h = 800 } } }
    return ui, function() return finds end
end

do
    lex = require("features.rare.lexicon").parse("#lang=zh\n龘\tdá\t9000\n普\tpǔ\t100")
    local ui, finds = newUi({ ["龘"] = { { start = { x = 10, y = 100, w = 30, h = 30 }, ["end"] = {} } } })
    local o = Overlay.new(ui)
    o:paint({})
    Assert.len(rendered, 1)
    Assert.eq(rendered[1].text, "dá")
    Assert.eq(finds(), 1)
    -- 同一视口走缓存，不再 findText。
    rendered = {}
    o:paint({})
    Assert.len(rendered, 1)
    Assert.eq(finds(), 1)
    -- 没有生僻字：不调 findText，不画。
    screen_text = "普通文字"
    Overlay.invalidate()
    rendered = {}
    o:paint({})
    Assert.len(rendered, 0)
    Assert.eq(finds(), 1)
    -- 关闭开关：不画。
    screen_text = "龘"
    settings.rare_enabled = false
    Overlay.invalidate()
    o:paint({})
    Assert.len(rendered, 0)
    settings.rare_enabled = true
end

do
    -- 英文整词：前后紧邻是字母或撇号的命中不算（findText 是子串搜索）。
    local text = "an obdurate, obdurately; the obdurate's x"
    local doc = {
        getPrevVisibleChar = function(_self, i) if i > 1 then return i - 1 end end,
        getNextVisibleChar = function(_self, i) if i <= #text then return i + 1 end end,
        getTextFromXPointers = function(_self, a, b) return text:sub(a, b - 1) end,
    }
    local function hit(from)
        local s = text:find("obdurate", from, true)
        return { start = s, ["end"] = s + #"obdurate" }, s
    end
    local m1, s1 = hit(1)
    Assert.is_true(Overlay.wholeWord(doc, m1))
    local m2, s2 = hit(s1 + 1)
    Assert.is_true(not Overlay.wholeWord(doc, m2))
    local m3 = hit(s2 + 1)
    Assert.is_true(not Overlay.wholeWord(doc, m3))
    -- 段首、段尾没有前后字符也算整词。
    text = "obdurate"
    Assert.is_true(Overlay.wholeWord(doc, { start = 1, ["end"] = 9 }))
end

do
    -- 点注音或被注音的字：开查词面板，带读音与屏上所在句子；关掉注音不接。
    local shown
    package.loaded["features.rare.lookup"] = { open = function(opts) shown = opts end }
    package.loaded["reader.context"].sentence = function(text, word) return "句子:" .. word end
    local ui = newUi({})
    local o = Overlay.new(ui)
    o.items = { { text = "dá", key = "龘", x = 10, y = 90, w = 20, size = 15, box = { x = 10, y = 100, w = 30, h = 30 } } }
    o.key = require("reader.page_marks").viewKey(ui, 0)
    Assert.is_false(o:tap({ x = 20, y = 115 }), "注音修订号不符：旧坐标作废")
    Overlay.invalidate()
    o.key = nil
    Assert.is_false(o:tap({ x = 20, y = 115 }), "未画过本视口")
    local item = o.items[1]
    o:paint({})
    o.items = { item }
    Assert.is_true(o:tap({ x = 15, y = 85 }), "点注音")
    Assert.eq(shown.text, "龘")
    Assert.eq(shown.reading, "dá")
    Assert.eq(shown.context.sentence, "句子:龘")
    shown = nil
    Assert.is_true(o:tap({ x = 20, y = 115 }), "点字")
    Assert.eq(shown.text, "龘")
    Assert.is_false(o:tap({ x = 300, y = 300 }))
    Assert.is_false(o:tap({ x = 35, y = 88 }), "上一行正文（原半行容错区）不接")
    Assert.is_false(o:tap({ x = 45, y = 115 }), "同行旁边的普通字不接")
    -- 翻页后还没重画：旧坐标不接，点按交给翻页。
    ui.document.getCurrentPos = function() return 1 end
    Assert.is_false(o:tap({ x = 20, y = 115 }), "视口变了")
    ui.document.getCurrentPos = function() return 0 end
    settings.rare_enabled = false
    Assert.is_false(o:tap({ x = 20, y = 115 }))
    settings.rare_enabled = true
end
