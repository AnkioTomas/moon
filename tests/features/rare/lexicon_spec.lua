--[[-- features.rare.lexicon：解析、阈值、中文最长匹配、英文切词与词形还原。 --]]

local Assert = require("support.assert")
local Lexicon = require("features.rare.lexicon")

local ZH = table.concat({
    "#name=测试拼音", "#lang=zh", "#levels=6500,3500,0",
    "一\tyī\t1", "曏\txiàng\t9000", "龘\tdá\t9000", "觊\tjì\t5000", "一曏\tyī xiàng\t9000",
    "坏行没有rank",
}, "\n")

local EN = table.concat({
    "#name=t", "#lang=en", "#levels=20000,8000,0",
    "the\t/ðә/\t1", "ubiquitous\t/ju:'bikwitәs/\t8148", "lugubrious\t/lu:'gju:briәs/\t28108",
    "study\t/'stʌdi/\t300", "garble\t/'gɑ:bl/\t25000",
}, "\n")

do
    local lex = Lexicon.parse(ZH)
    Assert.eq(lex.lang, "zh")
    Assert.eq(lex.meta.name, "测试拼音")
    Assert.eq(lex.count, 5)
    Assert.eq(lex.max_len, 2)
    Assert.eq(Lexicon.threshold(lex, "rarest"), 6500)
    Assert.eq(Lexicon.threshold(lex, "rare"), 3500)
    Assert.eq(Lexicon.threshold(lex, "all"), 0)
end

do
    -- 缺 levels 用语言默认；没有条目报错。
    Assert.eq(Lexicon.parse("#lang=en\nfoo\t/f/\t3").levels[1], 20000)
    Assert.errors(function() Lexicon.parse("#lang=zh\n") end, "empty lexicon")
end

do
    local lex = Lexicon.parse(ZH)
    -- 词组最长匹配覆盖单字首选读音，去重，ASCII 跳过。
    local hits = Lexicon.match(lex, "abc一曏觊龘，龘", 3500)
    Assert.len(hits, 3)
    Assert.eq(hits[1].key, "一曏")
    Assert.eq(hits[1].ann, "yī xiàng")
    Assert.eq(hits[2].key, "觊")
    Assert.eq(hits[3].key, "龘")
    -- 最生僻只留 rank > 6500。
    hits = Lexicon.match(lex, "觊龘", 6500)
    Assert.len(hits, 1)
    Assert.eq(hits[1].key, "龘")
    -- 全部：常用字也注；limit 截断。
    Assert.len(Lexicon.match(lex, "一龘觊", 0), 3)
    Assert.len(Lexicon.match(lex, "一龘觊", 0, 2), 2)
end

do
    Assert.len(Lexicon.words("It's a Ubiquitous-thing, 42x"), 6)
    Assert.contains(Lexicon.stems("studies"), "study")
    Assert.contains(Lexicon.stems("garbled"), "garble")
    Assert.contains(Lexicon.stems("garbling"), "garble")
    local lex = Lexicon.parse(EN)
    local hits = Lexicon.match(lex, "The UBIQUITOUS, lugubrious studies were garbled. Lugubrious!", 8000)
    Assert.len(hits, 4)
    Assert.eq(hits[1].key, "UBIQUITOUS")
    Assert.eq(hits[1].ann, "/ju:'bikwitәs/")
    Assert.eq(hits[2].key, "lugubrious")
    Assert.eq(hits[3].key, "garbled")
    Assert.eq(hits[3].ann, "/'gɑ:bl/")
    -- 大小写不同算不同原文（findText 忽略大小写，画两次也只命中同样的框）。
    Assert.eq(hits[4].key, "Lugubrious")
    Assert.len(Lexicon.match(lex, "ubiquitous lugubrious", 20000), 1)
end
