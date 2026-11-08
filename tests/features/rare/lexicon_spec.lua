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
    Assert.eq(lex.kind, "ruby", "缺 #kind 默认 ruby")
    Assert.eq(lex.meta.name, "测试拼音")
    Assert.eq(lex.count, 5)
    Assert.eq(lex.max_len, 2)
    Assert.eq(Lexicon.threshold(lex, "rarest"), 6500)
    Assert.eq(Lexicon.threshold(lex, "rare"), 3500)
    Assert.eq(Lexicon.threshold(lex, "all"), 0)
end

do
    -- 缺 levels 用语言默认；没有条目报错；#kind=wordwise。
    Assert.eq(Lexicon.parse("#lang=en\nfoo\t/f/\t3").levels[1], 20000)
    Assert.eq(Lexicon.parse("#lang=en\n#kind=wordwise\nfoo\t短\t3").kind, "wordwise")
    Assert.eq(Lexicon.parse("#lang=en\n#kind=nope\nfoo\t短\t3").kind, "ruby", "未知 kind 当 ruby")
    Assert.errors(function() Lexicon.parse("#lang=zh\n") end, "empty lexicon")
end

do
    Assert.contains(Lexicon.stems("studies"), "study")
    Assert.contains(Lexicon.stems("garbled"), "garble")
    Assert.contains(Lexicon.stems("garbling"), "garble")
end

do
    -- scan：逐字单元上每一处命中都给（不去重），带位置；force 的词不看阈值；en 按字母成词、带撇号的不查。
    local zh = Lexicon.parse("#lang=zh\n一\tyī\t1\n龘\tdá\t9000\n觊觎\tjì yú\t7000\n觊\tjì\t7000")
    local hits = Lexicon.scan(zh, { "a", "一", "龘", "觊", "觎", "龘" }, 3500)
    local got = {}
    for _, h in ipairs(hits) do got[#got + 1] = h.key .. "@" .. h.i .. "+" .. h.n end
    Assert.eq(table.concat(got, ","), "龘@3+1,觊@4+1,觎@5+1,龘@6+1")
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
    local lex = Lexicon.parse("#lang=zh\n长\tzhǎng\t127\n江\tjiāng\t538\n河\thé\t1000\n"
        .. "长江\tcháng jiāng\t538\n长江大桥\tcháng jiāng dà qiáo\t3000")
    local hits = Lexicon.scan(lex, { "长", "江" }, 0)
    Assert.len(hits, 2, "屏尾长度不足时仍查到较短词组")
    Assert.eq(hits[1].ann, "cháng")
    hits = Lexicon.scan(lex, { "长", "河" }, 0)
    Assert.len(hits, 2, "首字有词组但未匹配时退回单字")
    Assert.eq(hits[1].ann, "zhǎng")
    Assert.eq(hits[2].ann, "hé")
    hits = Lexicon.scan(lex, { "河" }, 0)
    Assert.eq(hits[1].ann, "hé", "没有词组的首字直接查单字")
end

do
    local lex = Lexicon.parse(table.concat({
        "#lang=zh", "长\tzhǎng\t127", "江\tjiāng\t800", "长江\tcháng jiāng\t800",
        "酩\tmǐng\t5400", "酊\tdīng\t5000", "大\tdà\t32", "醉\tzuì\t2400",
        "酩酊大醉\tmǐng dǐng dà zuì\t5400",
    }, "\n"))
    local river = { "长", "江" }
    Assert.len(Lexicon.scan(lex, river, 3500), 0, "词组定音不强制标注常见字")
    local hits = Lexicon.scan(lex, river, 3500, { ["长"] = true })
    Assert.len(hits, 1, "低于阈值的词组仍能给生字本里的单字定音")
    Assert.eq(hits[1].ann, "cháng")
    Assert.eq(hits[1].key, "长")
    Assert.eq(hits[1].n, 1)
    hits = Lexicon.scan(lex, river, 0)
    Assert.len(hits, 2, "全部档逐字标注")
    Assert.eq(hits[1].ann, "cháng")
    Assert.eq(hits[2].ann, "jiāng")
    Assert.len(Lexicon.scan(lex, river, 3500, { ["长江"] = true }), 2, "生字本里的整词仍强制标注")
    local drunk = { "酩", "酊", "大", "醉" }
    hits = Lexicon.scan(lex, drunk, 3500)
    Assert.len(hits, 2, "生僻词组不带出常见字")
    Assert.eq(hits[1].key, "酩")
    Assert.eq(hits[2].key, "酊")
    Assert.eq(hits[2].i, 2)
    Assert.eq(hits[2].ann, "dǐng", "筛选用单字排名，读音用词组")
    hits = Lexicon.scan(lex, drunk, 3500, nil, 1)
    Assert.len(hits, 1, "词组拆字仍遵守命中上限")
    Assert.eq(hits[1].key, "酩")
    local custom = Lexicon.parse("#lang=zh\n长江\tChangjiang\t5000")
    hits = Lexicon.scan(custom, river, 3500)
    Assert.eq(hits[1].n, 2, "未逐字分隔的自制注音保留整词")
    Assert.eq(hits[1].ann, "Changjiang")
    local gloss = Lexicon.parse("#lang=zh\n#kind=wordwise\n长江\t中国最长河流\t5000")
    hits = Lexicon.scan(gloss, river, 3500)
    Assert.eq(hits[1].n, 2, "中文释义不拆字")
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
    hits = Lexicon.scan(lex, { "酩", "酊", "大", "醉" }, Lexicon.threshold(lex, "rare"))
    Assert.len(hits, 2, "实际词库生僻档不标注词组里的常见字")
    Assert.eq(hits[1].key, "酩")
    Assert.eq(hits[2].key, "酊")
    for _idx, sample in ipairs({
        { "长江", "cháng jiāng" }, { "银行", "yín háng" }, { "重庆", "chóng qìng" },
        { "音乐", "yīn yuè" }, { "头发", "tóu fà" }, { "重复", "chóng fù" },
        { "長江", "cháng jiāng" }, { "銀行", "yín háng" }, { "頭髮", "tóu fà" },
    }) do
        local units = {}
        for char in sample[1]:gmatch("[\194-\244][\128-\191]*") do units[#units + 1] = char end
        Assert.len(Lexicon.scan(lex, units, Lexicon.threshold(lex, "rare")), 0, sample[1] .. " 只定音、不强制标注")
        hits = Lexicon.scan(lex, units, Lexicon.threshold(lex, "all"))
        local readings = {}
        for _h, hit in ipairs(hits) do readings[#readings + 1] = hit.ann end
        Assert.eq(table.concat(readings, " "), sample[2], sample[1] .. " 按词组定音")
    end
    hits = Lexicon.scan(lex, { "长", "江", "长", "大" }, Lexicon.threshold(lex, "rare"), { ["长"] = true })
    Assert.len(hits, 2)
    Assert.eq(hits[1].ann, "cháng", "相同字在同页不同词里选不同读音")
    Assert.eq(hits[2].ann, "zhǎng")
    Assert.is_true(#text < 600 * 1024, "词库保持小体积（512MB Kindle 常驻内存）")
    local mf = assert(io.open("assets/rare/zh-pinyin/manifest.json", "rb"))
    local manifest = mf:read("*a")
    mf:close()
    Assert.matches(manifest, '"raw_size": ' .. #text)
end

do
    -- WordWise 中/英短义词库（tools/build_rare_gloss.py）：#kind=wordwise，短义够短。
    for _idx, id in ipairs({ "en-gloss-zh", "en-gloss-en" }) do
        local path = "assets/rare/" .. id .. "/lexicon.tsv.part.001"
        local f = assert(io.open(path, "rb"))
        local text = f:read("*a")
        f:close()
        local lex = Lexicon.parse(text)
        Assert.eq(lex.lang, "en", id)
        Assert.eq(lex.kind, "wordwise", id)
        Assert.is_true(lex.count > 10000, id .. " 覆盖量")
        local sample = lex.entries["ubiquitous"]
        Assert.not_nil(sample, id .. " ubiquitous")
        local ann = sample[1]
        local n = select(2, ann:gsub("[^\128-\191]", ""))
        Assert.is_true(n <= 24, id .. " 短义长度 " .. ann)
        Assert.is_true(#text < 2 * 1024 * 1024, id .. " 体积")
        local mf = assert(io.open("assets/rare/" .. id .. "/manifest.json", "rb"))
        local manifest = mf:read("*a")
        mf:close()
        Assert.matches(manifest, '"raw_size": ' .. #text)
    end
end

do
    -- 同 span：wordwise 压过 ruby；不重叠的中英命中都保留。
    local merged = Lexicon.dedupe({
        { i = 1, n = 1, key = "龘", ann = "dá", kind = "ruby" },
        { i = 3, n = 8, key = "obdurate", ann = "/ɒb/", kind = "ruby" },
        { i = 3, n = 8, key = "obdurate", ann = "顽固的", kind = "wordwise" },
    })
    Assert.len(merged, 2)
    Assert.eq(merged[1].ann, "顽固的", "英文同词留释义")
    Assert.eq(merged[2].ann, "dá")
end
