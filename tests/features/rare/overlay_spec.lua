--[[-- features.rare.overlay：注音布局（全屏统一字号、居中、夹边）、点按开查词面板与绘制管线（桩 CRE）。 --]]

local Assert = require("support.assert")

local settings = {
    rare_enabled = true, rare_ruby = true, rare_wordwise = false, rare_split_migrated = true,
    rare_level = "rare", rare_size = 0.5, rare_lexicons = { t = true }, rare_built_at = {},
}
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
local lex
package.preload["features.rare.catalog"] = function()
    return {
        active = function() return { lex } end,
        warm = function() return 0 end,
        kind = function() return "ruby" end,
        -- 翻页前只查文件是否在；桩给个假路径，配合下面的 lfs stub。
        path = function(id) return id == "t" and "/tmp/rare-overlay-stub.tsv" or nil end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path) return path == "/tmp/rare-overlay-stub.tsv" and "file" or nil end }
end
local screen_text = "普通文字龘"
package.preload["reader.context"] = function()
    return { visibleText = function() return screen_text end }
end
package.preload["reader.session"] = function()
    return { current = function() return { identity = { source_id = "local", stable_id = "x", chapter_idx = 1 } } end }
end
-- 注音字体按像素直接开 FreeType 面（NotoSans 是 KOReader 自带字体，必在）。
package.preload["fontlist"] = function() return { fontdir = "/fonts" } end
package.preload["ffi/freetype"] = function()
    return { newFaceSize = function(_path, px) return { px = px, done = function() end } end }
end
local rendered = {}
package.preload["ui/rendertext"] = function()
    return {
        sizeUtf8Text = function(_self, _x, _w, face, text) return { x = #text * face.size / 2 } end,
        renderUtf8Text = function(_self, _bb, x, y, face, text, _k, _b, color)
            rendered[#rendered + 1] = { x = x, y = y, size = face.size, text = text, color = color }
        end,
    }
end
package.preload["apps/reader/readerui"] = function() return {} end

-- 子进程桩：同步跑 worker 再回调（真机 fork 后 JSON 回传）。
package.preload["workers.job"] = function()
    return { run = function(worker, opts)
        local ok, result = pcall(worker)
        if ok then opts.on_done(result) else opts.on_failed(result) end
        return { settled = true, cancel = function() end }
    end }
end
package.preload["device"] = function() return { screen = { bb = {} } } end
local Stubs = require("support.stubs")
local Overlay = require("features.rare.overlay")

--- 视口变了：这一帧排队，下一 tick 重算，再画一帧。
local function draw(o)
    o:paint({})
    Stubs.flush()
    o:paint({})
end

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

-- 桩 CRE：屏上文字逐字一个 xpointer "t.<序号>"；字框横排，每字 30px。
package.loaded["ffi/blitbuffer"] = { COLOR_DARK_GRAY = 1, COLOR_BLACK = 0 }
local function newUi()
    local calls = { boxes = 0, walks = 0 }
    local function chars()
        local out = {}
        for c in screen_text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = c end
        return out
    end
    local function idx(xp) return tonumber(xp:match("(%d+)$")) end
    local doc = {
        getTextFromPositions = function()
            calls.walks = calls.walks + 1
            return { text = screen_text, pos0 = "t.0", pos1 = "t." .. (#chars() - 1) }
        end,
        compareXPointers = function(_self, a, b)
            if idx(a) == idx(b) then return 0 end
            return idx(a) < idx(b) and 1 or -1
        end,
        getNextVisibleChar = function(_self, xp)
            local n = idx(xp) + 1
            if n < #chars() then return "t." .. n end
        end,
        getTextFromXPointers = function(_self, a, b)
            return table.concat(chars(), "", idx(a) + 1, idx(b))
        end,
        getScreenBoxesFromPositions = function(_self, a, b)
            calls.boxes = calls.boxes + 1
            return { { x = idx(a) * 30, y = 100, w = (idx(b) - idx(a)) * 30, h = 30 } }
        end,
        getCurrentPos = function() return 0 end,
    }
    local ui = { rolling = {}, document = doc, view = { dimen = { w = 600, h = 800 } } }
    return ui, calls
end

do
    lex = require("features.rare.lexicon").parse("#lang=zh\n龘\tdá\t9000\n普\tpǔ\t100\n通\ttōng\t50\n文\twén\t20\n字\tzì\t30")
    local ui, calls = newUi()
    local o = Overlay.new(ui)
    o:paint({})
    Assert.len(rendered, 0, "翻页这一帧只排队，不同步重算")
    Assert.eq(calls.walks, 0)
    Stubs.flush()
    o:paint({})
    Assert.len(rendered, 1)
    Assert.eq(rendered[1].text, "dá")
    Assert.eq(rendered[1].color, 1, "注音深灰（与正文黑区分）")
    Assert.eq(calls.boxes, 1, "只给命中的字取框")
    -- 同一视口走缓存，不再走字。
    rendered = {}
    o:paint({})
    Assert.len(rendered, 1)
    Assert.eq(calls.walks, 1)
    -- 没有生僻字：不取框，不画。
    screen_text = "普通文字"
    Overlay.invalidate()
    rendered = {}
    draw(o)
    Assert.len(rendered, 0)
    Assert.eq(calls.boxes, 1)
    -- 「全部」：屏上每个字都注（不再有 80 词 / findText 预算上限）。
    settings.rare_level = "all"
    screen_text = string.rep("普通文字", 40)
    Overlay.invalidate()
    draw(o)
    Assert.eq(calls.boxes, 1 + 160, "160 个字每处都取框")
    settings.rare_level = "rare"
    -- 生字本：生字本里的字不看档位也注。
    package.loaded["features.rare.vocab"] = { set = function() return { ["通"] = true } end }
    settings.rare_vocab = true
    screen_text = "普通文字"
    Overlay.invalidate()
    rendered = {}
    draw(o)
    Assert.len(rendered, 1)
    Assert.eq(rendered[1].text, "tōng")
    settings.rare_vocab = false
    Overlay.invalidate()
    rendered = {}
    draw(o)
    Assert.len(rendered, 0, "关掉生字本就按档位")
    -- 关闭注音开关：不画。
    screen_text = "龘"
    settings.rare_ruby = false
    settings.rare_enabled = false
    Overlay.invalidate()
    draw(o)
    Assert.len(rendered, 0)
    settings.rare_ruby = true
    settings.rare_enabled = true
    screen_text = "普通文字龘"
end

do
    -- 走字：空白保留为空格单元（英文词界），止于 pos1（含）；取框终点是同节点偏移 +1。
    local text = { "a", " ", "b", "c", "d" }
    local function n(xp) return tonumber(xp:match("%d+$")) end
    local doc = {
        compareXPointers = function(_self, a, b)
            return n(a) == n(b) and 0 or (n(a) < n(b) and 1 or -1)
        end,
        getNextVisibleChar = function(_self, xp) if n(xp) < #text - 1 then return "p/text()." .. (n(xp) + 1) end end,
        getTextFromXPointers = function(_self, a, b) return table.concat(text, "", n(a) + 1, n(b)) end,
    }
    local units = Overlay.walk(doc, "p/text().0", "p/text().3")
    local got = {}
    for _, u in ipairs(units) do got[#got + 1] = u.text .. "@" .. u.xp .. ">" .. u.stop end
    Assert.eq(table.concat(got, ","), "a@p/text().0>p/text().1, @p/text().1>p/text().2,b@p/text().2>p/text().3,c@p/text().3>p/text().4")
end

do
    -- 空格断词：walk 保留空格后，英文 lexicon 才能把 The ubiquitous 拆开（否则黏成 Theubiquitous）。
    local text = { "T", "h", "e", " ", "u", "b", "i", "q", "u", "i", "t", "o", "u", "s", " ", "x" }
    local function n(xp) return tonumber(xp:match("%d+$")) end
    local doc = {
        compareXPointers = function(_self, a, b)
            return n(a) == n(b) and 0 or (n(a) < n(b) and 1 or -1)
        end,
        getNextVisibleChar = function(_self, xp) if n(xp) < #text - 1 then return "p/text()." .. (n(xp) + 1) end end,
        getTextFromXPointers = function(_self, a, b) return table.concat(text, "", n(a) + 1, n(b)) end,
    }
    local units = Overlay.walk(doc, "p/text().0", "p/text()." .. (#text - 1))
    local texts = {}
    for i, u in ipairs(units) do texts[i] = u.text end
    local Lexicon = require("features.rare.lexicon")
    local lex = Lexicon.parse("#lang=en\n#kind=wordwise\n#levels=20000,8000,3000\nubiquitous\tomnipresent\t9000\n")
    local hits = Lexicon.scan(lex, texts, 8000)
    Assert.len(hits, 1)
    Assert.eq(hits[1].key, "ubiquitous")
end
