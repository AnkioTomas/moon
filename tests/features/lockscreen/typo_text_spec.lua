--[[--
文字海报：避头尾断行、竖排标点、关键词。
@module tests.features.lockscreen.typo_text_spec
--]]

local Assert = require("support.assert")
local T = require("features.lockscreen.typo_text")

do -- 按容量断行（「五六」是词表里的一个词，整体挪到下一行）
    local lines = T.breakLines("一二三四五六七", 3)
    Assert.eq(table.concat(lines, "|"), "一二三|四五|六七")
end

do -- 行首禁则：逗号句号挂在上一行末，不另起一行开头
    local lines = T.breakLines("一二三，四五六。", 3)
    Assert.eq(table.concat(lines, "|"), "一二三，|四五六。")
end

do -- 行尾禁则：开引号推到下一行
    local lines = T.breakLines("一二「三四」", 3)
    Assert.eq(table.concat(lines, "|"), "一二|「三四」")
end

do -- 拉丁单词不拆开，行首空格丢掉
    local lines = T.breakLines("we are all guilty", 7)
    Assert.eq(table.concat(lines, "|"), "we are|all|guilty")
end

do -- 自定义宽度：拉丁单词按 measure 计
    local lines = T.breakLines("ab cd", 2, function(u) return u == " " and 1 or 2 end)
    Assert.eq(table.concat(lines, "|"), "ab|cd")
end

do -- 按词断行：不把词拆到两行；关键词整体不拆
    local lines = T.breakLines("就是要在虚无之中找出意义", 5)
    for _idx, l in ipairs(lines) do Assert.is_true(not l:match("^无") and not l:match("^义"), l) end
    lines = T.breakLines("你就说你没有天赋。", 7, nil, "没有天赋")
    Assert.eq(table.concat(lines, "|"), "你就说你|没有天赋。")
end

do -- 分句：标点留在句尾，连续标点不拆，英文要后跟空格
    Assert.eq(table.concat(T.clauses("我是大学生，不要对我哇啦哇啦！"), "|"), "我是大学生，|不要对我哇啦哇啦！")
    Assert.eq(table.concat(T.clauses("真的吗？！是的。"), "|"), "真的吗？！|是的。")
    Assert.eq(table.concat(T.clauses("Pi is 3.14, really"), "|"), "Pi is 3.14,|really")
end

do -- 候选词：高分在前、去重
    local words = T.topWords("你既没有耐心，也没有勇气，现在沮丧发作，你就说你没有天赋。", 3)
    Assert.eq(#words, 3)
    Assert.eq(words[1], T.keyword("你既没有耐心，也没有勇气，现在沮丧发作，你就说你没有天赋。"))
end

do -- 竖排标点
    Assert.eq(T.vertical("，"), "︐")
    Assert.eq(T.vertical("「"), "﹁")
    Assert.eq(T.vertical("字"), "字")
end

do -- 分词：最大概率，不从句中硬切
    Assert.eq(table.concat(T.segment("人活着，就是要在虚无之中找出意义"), "/"), "人/活着/，/就是/要/在/虚无/之中/找出/意义")
end

do -- 关键词：标记优先；否则分词打分取实词
    Assert.eq(T.keyword("人是【奥秘】，需要解开"), "奥秘")
    local cases = {
        { "人活着，就是要在虚无之中找出意义", "意义" },
        { "我们每个人都对所有人负有罪责", "罪责" },
        { "痛苦和受难对于博大的意识永远是必需的", "意识" },
        { "人一旦习惯了痛苦，痛苦也就成了他的家。", "痛苦" },
        { "清醒是一种病，一种真正的、彻头彻尾的病。", "清醒" },
        { "我怕的不是死，而是配不上我所受的苦难。", "苦难" },
        { "世界上只有一种真正的英雄主义，那就是认清生活的真相后依然热爱生活", "生活" },
        { "人的一切痛苦，本质上都是对自己无能的愤怒", "本质" },
        { "我们终此一生，就是要摆脱他人的期待，找到真正的自己", "期待" },
        { "凡是过往，皆为序章", "过往" },
        { "时间会刺破青春表面的彩饰", "青春" },
        { "孤独是生命的礼物", "礼物" },
        { "你要搞清楚自己人生的剧本", "剧本" },
        { "万物皆有裂痕，那是光照进来的地方", "裂痕" },
        { "生活不可能像你想象得那么好，但也不会像你想象得那么糟", "想象" },
        { "Pain and suffering are inevitable", "inevitable" },
    }
    for _idx, c in ipairs(cases) do Assert.eq(T.keyword(c[1]), c[2], c[1]) end
    -- 挑不出像样的词就不放大
    Assert.is_nil(T.keyword("希望是一种好东西，也许是最好的东西"))
    Assert.is_nil(T.keyword("就是这样"))
    Assert.eq(T.strip("人是【奥秘】"), "人是奥秘")
end

return true
