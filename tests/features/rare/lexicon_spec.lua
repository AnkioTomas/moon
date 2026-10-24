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

do
    -- scan：逐字单元上每一处命中都给（不去重），带位置；force 的词不看阈值；en 按字母成词、带撇号的不查。
    local zh = Lexicon.parse("#lang=zh\n一\tyī\t1\n龘\tdá\t9000\n觊觎\tjì yú\t7000\n觊\tjì\t7000")
    local hits = Lexicon.scan(zh, { "a", "一", "龘", "觊", "觎", "龘" }, 3500)
    local got = {}
    for _, h in ipairs(hits) do got[#got + 1] = h.key .. "@" .. h.i .. "+" .. h.n end
    Assert.eq(table.concat(got, ","), "龘@3+1,觊觎@4+2,龘@6+1")
    Assert.len(Lexicon.scan(zh, { "一", "一" }, 0), 2, "全部档每处都注")
    Assert.len(Lexicon.scan(zh, { "一", "一" }, 3500), 0)
    Assert.len(Lexicon.scan(zh, { "一", "一" }, 3500, { ["一"] = true }), 2, "生字本里的字不看阈值")
    Assert.len(Lexicon.scan(zh, { "龘", "龘", "龘" }, 0, nil, 2), 2, "limit")
    local en = Lexicon.parse("#lang=en\nobdurate\tˈɒbdjʊrət\t30000\nstudy\tˈstʌdi\t500")
    -- 逐字单元里空白已去掉，用标点隔开测整词。
    local units = {}
    for c in ("an,Obdurate,obdurately,obdurate's,studies"):gmatch(".") do units[#units + 1] = c end
    hits = Lexicon.scan(en, units, 8000)
    Assert.len(hits, 1)
    Assert.eq(hits[1].key, "Obdurate")
    Assert.eq(hits[1].i, 4)
    Assert.eq(hits[1].n, 8)
    Assert.len(Lexicon.scan(en, units, 8000, { studies = true }), 2, "生字本英文词（含词形还原）")
end


do
    -- 仓库里的汉字拼音词库（tools/build_rare_pinyin.py 生成）：含繁体字与繁体词组，读音取繁体本字，rank 随简体。
    local f = assert(io.open("assets/rare/zh-pinyin/lexicon.tsv.part.001", "rb"))
    local text = f:read("*a")
    f:close()
    local lex = Lexicon.parse(text)
    Assert.eq(lex.lang, "zh")
    for _idx, pair in ipairs({ { "時", "时" }, { "尋", "寻" }, { "讀", "读" }, { "無", "无" } }) do
        local t, s = lex.entries[pair[1]], lex.entries[pair[2]]
        Assert.not_nil(t, pair[1])
        Assert.eq(t[1], s[1], pair[1])
        Assert.eq(t[2], s[2], pair[1] .. " rank 随简体")
    end
    Assert.eq(lex.entries["乾"][1], "qián", "繁体读音取本字，不照抄简体「干」")
    local hits = Lexicon.scan(lex, { "時", "無", "讀" }, Lexicon.threshold(lex, "all"))
    Assert.len(hits, 3, "「全部」档繁体字都注音")
    Assert.eq(lex.entries["龘"][1], "dá", "字表外冷僻字也收")
    Assert.is_true(#text < 600 * 1024, "词库保持小体积（512MB Kindle 常驻内存）")
    local mf = assert(io.open("assets/rare/zh-pinyin/manifest.json", "rb"))
    local manifest = mf:read("*a")
    mf:close()
    Assert.matches(manifest, '"raw_size": ' .. #text)
end
