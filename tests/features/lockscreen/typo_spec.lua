--[[--
文字海报：五种版式的绘制指令不越界（颗粒巨字可出血），竖排用竖排标点，设置值校验。
@module tests.features.lockscreen.typo_spec
--]]

local Assert = require("support.assert")
local T = require("features.lockscreen.typo_text")
local Typo = require("features.lockscreen.typo")

local function measure(text, px)
    local w = 0
    for _idx, ch in ipairs(T.chars(text)) do w = w + (#ch == 1 and px * 0.55 or px) end
    return w
end

local quotes = {
    { text = "我们每个人，都对所有人负有罪责，而我比所有人更有罪。", title = "卡拉马佐夫兄弟", author = "陀思妥耶夫斯基" },
    { text = "人是【奥秘】。", title = "", author = "" },
    { text = "To go wrong in one's own way is better than to go right in someone else's.", title = "Crime", author = "F. D." },
}

for _idx, size in ipairs({ { 1072, 1448 }, { 600, 800 }, { 1448, 1072 } }) do
    local w, h = size[1], size[2]
    for _i, style in ipairs({ "horizontal", "vertical", "backdrop", "scatter", "collage" }) do
        for _j, q in ipairs(quotes) do
            local ops = Typo.plan(style, q, w, h, measure)
            Assert.is_true(#ops > 0)
            for _k, op in ipairs(ops) do
                if op.t == "text" and not op.grain then
                    local right = op.x + measure(op.s, op.size)
                    -- 行末悬挂标点允许多出一个字宽
                    Assert.is_true(op.x >= 0 and right <= w + op.size, style .. " overflow x: " .. op.s)
                    Assert.is_true(op.y >= 0 and op.y + op.size <= h + 1, style .. " overflow y: " .. op.s)
                end
            end
        end
    end
end

do -- 竖排把逗号换成竖排形，标记关键词单独成列
    local ops = Typo.plan("vertical", quotes[1], 1072, 1448, measure)
    local seen = {}
    for _idx, op in ipairs(ops) do if op.t == "text" then seen[op.s] = true end end
    Assert.is_true(seen["︐"] == true)
    Assert.is_nil(seen["，"])
end

do -- 署名
    Assert.eq(Typo.attribution(quotes[1]), "—— 《卡拉马佐夫兄弟》 陀思妥耶夫斯基")
    Assert.eq(Typo.attribution(quotes[2]), "")
end

do -- 没有关键词：巨字铺底退回横排，不画浅灰巨字
    local ops = Typo.plan("backdrop", { text = "就是这样", title = "", author = "" }, 1072, 1448, measure)
    for _idx, op in ipairs(ops) do Assert.is_nil(op.grain) end
    ops = Typo.plan("scatter", { text = "就是这样", title = "", author = "" }, 1072, 1448, measure)
    for _idx, op in ipairs(ops) do Assert.is_nil(op.grain) end
end

do -- 横排：关键词到句末不长时从关键词断开压底，压底字比首句大
    local ops = Typo.plan("horizontal", { text = "人活着，就是要在虚无之中找出意义", title = "", author = "" }, 1072, 1448, measure)
    local by = {}
    for _idx, op in ipairs(ops) do if op.t == "text" then by[op.s] = op end end
    Assert.is_true(by["意义"] ~= nil and by["人活着，"] ~= nil)
    Assert.is_true(by["意义"].size > by["人活着，"].size * 1.4)
    Assert.is_true(by["意义"].y > by["人活着，"].y)
end

do -- 行内放大：拼贴里关键词与同行正文同基线、字号更大
    local ops = Typo.plan("collage", { text = "你既没有耐心，你就说你没有【天赋】。", title = "群魔", author = "陀" }, 1072, 1448, measure)
    local kw
    for _idx, op in ipairs(ops) do
        if op.t == "text" and op.s == "天赋" and not kw then kw = op end
    end
    Assert.is_true(kw ~= nil)
    local base, mate = kw.y + kw.size * 0.88, nil
    for _idx, op in ipairs(ops) do
        if op.t == "text" and op ~= kw and op.size < kw.size and math.abs(op.y + op.size * 0.88 - base) <= 1 then mate = op end
    end
    Assert.is_true(mate ~= nil)
end

do -- 颗粒巨字带 grain 标记；ops 记下画布尺寸供裁剪
    local ops = Typo.plan("backdrop", quotes[2], 1072, 1448, measure)
    local grain = 0
    for _idx, op in ipairs(ops) do if op.grain then grain = grain + 1 end end
    Assert.eq(grain, 2)
    Assert.eq(ops.w, 1072)
    Assert.eq(ops.h, 1448)
end

do -- AI 关键词校验：必须是原句子串
    Assert.eq(Typo.validKeyword(" 「虚无」。\n", "人活着，就是要在虚无之中找出意义"), "虚无")
    Assert.is_nil(Typo.validKeyword("荒诞", "人活着，就是要在虚无之中找出意义"))
    Assert.is_nil(Typo.validKeyword("", "人活着"))
end

do -- 散落关键词：巨字整字落在页内、不压正文框、彼此不叠
    local texts = {
        "人活着，就是要在虚无之中找出意义",
        "你既没有耐心，也没有勇气，现在沮丧发作，你就说你没有天赋。",
        "你就像是死了，同时却又【活着】，一举两得。",
        "我是大学生，不要对我【哇啦哇啦】！",
    }
    for _idx, size in ipairs({ { 1072, 1448 }, { 600, 800 }, { 1448, 1072 } }) do
        local w, h = size[1], size[2]
        for _i, text in ipairs(texts) do
            local ops = Typo.plan("scatter", { text = text, title = "书", author = "作者" }, w, h, measure)
            local tb = Typo._textBox(ops, measure)
            local boxes = {}
            for _k, op in ipairs(ops) do
                if op.grain then
                    local b = { op.x, op.y, op.x + op.size, op.y + op.size }
                    Assert.is_true(b[1] >= 0 and b[2] >= 0 and b[3] <= w and b[4] <= h, "scatter overflow " .. op.s)
                    Assert.is_false(Typo._hit(b, tb), "scatter overlaps text " .. op.s)
                    boxes[#boxes + 1] = b
                end
            end
            Assert.is_true(#boxes > 0)
            for a = 1, #boxes do
                for b = a + 1, #boxes do
                    -- 同一个词的相邻字共边，不算重叠
                    local x, y = boxes[a], boxes[b]
                    Assert.is_true(not Typo._hit({ x[1] + 1, x[2] + 1, x[3] - 1, x[4] - 1 }, y), "scatter words overlap")
                end
            end
        end
    end
end

do -- 设置
    Assert.is_true(Typo.validStyle("random"))
    Assert.is_true(Typo.validStyle("collage"))
    Assert.is_false(Typo.validStyle("nope"))
    Assert.is_true(Typo.validStyle("scatter"))
    Assert.eq(#Typo.styleOptions(), 6)
end

do -- 短划线池按 notes 表戳缓存：戳不变不重读全库
    local NoteDB, Highlights = require("book.note_db"), require("book.highlights")
    local stamp_fn, collect_fn = NoteDB.stamp, Highlights.collectAll
    local stamp, reads = "s1", 0
    NoteDB.stamp = function() return stamp end
    Highlights.collectAll = function()
        reads = reads + 1
        return { { text = "一二三四五六七" }, { text = "短" } }
    end
    Assert.eq(#Typo.shortQuotes(60), 1)
    Assert.eq(#Typo.shortQuotes(60), 1)
    Assert.eq(reads, 1)
    stamp = "s2"
    Typo.shortQuotes(60)
    Assert.eq(reads, 2)
    Assert.eq(#Typo.shortQuotes(60, { { text = "一二三四五六" } }), 1)
    NoteDB.stamp, Highlights.collectAll = stamp_fn, collect_fn
end

return true
