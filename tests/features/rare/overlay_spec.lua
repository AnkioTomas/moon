--[[-- features.rare.overlay：注音布局（字号、缩放、居中、夹边、同行避让）与绘制管线（桩 CRE）。 --]]

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

do
    -- 字号 = 行高 × 比例；居中在框上方；基线在框顶。
    local items = Overlay.layout({ { ann = "dá", box = { x = 100, y = 50, w = 30, h = 30 } } },
        { ratio = 0.5, screen_w = 600, measure = measure })
    Assert.len(items, 1)
    Assert.eq(items[1].size, 15)
    Assert.eq(items[1].y, 50)
    -- "dá" 3 字节 × 7.5 = 22.5 宽，居中：100 + (30 - 22.5) / 2
    Assert.eq(items[1].x, 103)
end

do
    -- 过宽缩字号，但不小于六成；靠右越界夹回屏内；顶行基线不出屏。
    local items = Overlay.layout({ { ann = "zhuàng", box = { x = 580, y = 0, w = 20, h = 40 } } },
        { ratio = 0.5, screen_w = 600, measure = measure })
    Assert.eq(items[1].size, 12)
    Assert.eq(items[1].y, 12)
    Assert.is_true(items[1].x + measure("zhuàng", 12) <= 600)
end

do
    -- 同一行与前一个重叠的跳过，换行不受影响。
    local items = Overlay.layout({
        { ann = "aaaaaa", box = { x = 0, y = 10, w = 20, h = 20 } },
        { ann = "bbbbbb", box = { x = 20, y = 10, w = 20, h = 20 } },
        { ann = "cccccc", box = { x = 20, y = 40, w = 20, h = 20 } },
    }, { ratio = 0.5, screen_w = 600, measure = measure })
    Assert.len(items, 2)
    Assert.eq(items[2].text, "cccccc")
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
