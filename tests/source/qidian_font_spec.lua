--[[--
起点 cES=2 字体层：字段判定、诱饵副本裁剪、无字体时的兜底。

@module tests.source.qidian_font_spec
--]]

local Assert = require("support.assert")
local FontRestore = require("source.yuewen_fonts")
local Mapper = require("source.qidian.mapper")

-- Fock 与字体层是两个独立标记，不能再用 cES 非 0 一把抓。
Assert.is_true(Mapper.fockEncrypted({ fEnS = "1" }))
Assert.is_false(Mapper.fockEncrypted({ fEnS = "0", cES = "2" }))
Assert.is_true(Mapper.fontProtected({ cES = "2" }))
Assert.is_false(Mapper.fontProtected({ cES = "1" }))

-- 起点把同一章再追加一份同长度的诱饵副本；长度一一对应时丢掉后半。
local duplicate = { "甲甲乙乙", "乙乙乙乙乙", "甲甲乙乙", "乙乙乙乙丁" }
local trimmed = FontRestore.dropDecoyHalf(duplicate)
Assert.eq(#trimmed, 2)
Assert.eq(trimmed[1], "甲甲乙乙")
Assert.eq(trimmed[2], "乙乙乙乙乙")

local uneven = { "甲甲", "乙乙乙", "丙丙", "丁丁" }
Assert.eq(#FontRestore.dropDecoyHalf(uneven), 4)

local odd = { "甲甲", "乙乙乙", "丙丙" }
Assert.eq(#FontRestore.dropDecoyHalf(odd), 3)

-- 没有 fixedFont 时不进入 FreeType；仍应按 CSS 解析段落并裁剪诱饵。
local html = "<p>　　甲甲</p><p>　　乙乙乙</p><p>　　甲甲</p><p>　　乙乙乙</p>"
local text = FontRestore.restore(html, { css = "", randomFont = { data = {} } }, nil, { dedupe = true })
Assert.eq(text, "　　甲甲\n　　乙乙乙")

-- 于/干、责/贵 只修固定搭配；“干部/干活/干事/干劲”保留。
Assert.eq(FontRestore.fixConfusions("关干《链法总纲》终干敲定了"),
    "关于《链法总纲》终于敲定了")
Assert.eq(FontRestore.fixConfusions("对干宗门，对干部，在干活，等干事"),
    "对于宗门，对干部，在干活，等干事")
Assert.eq(FontRestore.fixConfusions("职贵、担贵、负贵、贵任"),
    "职责、担责、负责、责任")
Assert.eq(FontRestore.fixConfusions("同泮支援，泮随着，汇聚干此"),
    "同伴支援，伴随着，汇聚于此")

-- restore 内部也要能调用到 fixConfusions（不能是未赋值的全局）。
local text2 = FontRestore.restore("<p>关干《链法总纲》</p>", { css = "", randomFont = { data = {} } }, nil,
    { confusions = true })
Assert.eq(text2, "关于《链法总纲》")

-- 前后半字数相同但内容不同的真实对称段落不能被当诱饵删掉。
Assert.eq(#FontRestore.dropDecoyHalf({ "春风来", "夏雨至", "秋叶落", "冬雪飘" }), 4)

-- 常见搭配里的“干”不能被改成“于”。
Assert.eq(FontRestore.fixConfusions("在干什么，对干净的"), "在干什么，对干净的")

-- 识别使用主进程交下来的两条路径，正常 / glyph 抛错都及时删除。
do
    local Paths = require("utils.paths")
    local lfs = require("libs/libkoreader-lfs")
    local dir = Paths.tmpDir() .. "/font_restore_spec"
    assert(Paths.ensureDir(dir .. "/noto"))
    local ref = dir .. "/noto/NotoSansCJKsc-Regular.otf"
    local file = assert(io.open(ref, "wb"))
    assert(file:write("reference"))
    assert(file:close())
    local old_fontlist, old_glyph = package.loaded["fontlist"], package.loaded["utils.glyph"]
    package.loaded["fontlist"] = { fontdir = dir }
    local paths = { Paths.tmpname(".font"), Paths.tmpname(".font") }
    local fixed = "\0\1\0\0fixed"
    package.loaded["utils.glyph"] = {
        recognize = function(_ref, _cache, tasks)
            Assert.eq(tasks[1].font_path, paths[1])
            Assert.eq(tasks[2].font_path, paths[2])
            local font = assert(io.open(tasks[2].font_path, "rb"))
            Assert.eq(font:read("*a"), fixed)
            font:close()
            return { { [0x4909] = "乙" }, { [0x7532] = "丙" } }
        end,
    }
    local font = { css = "", randomFont = { data = { 0, 1, 0, 0 } } }
    Assert.eq(FontRestore.restore("<p>甲䤉</p>", font, fixed, { temp_paths = paths }), "丙乙")
    for _idx, path in ipairs(paths) do Assert.is_nil(lfs.attributes(path)) end
    package.loaded["utils.glyph"].recognize = function() error("glyph failed", 0) end
    Assert.errors(function()
        FontRestore.restore("<p>甲䤉</p>", font, fixed, { temp_paths = paths })
    end, "glyph failed")
    for _idx, path in ipairs(paths) do Assert.is_nil(lfs.attributes(path)) end
    package.loaded["fontlist"], package.loaded["utils.glyph"] = old_fontlist, old_glyph
    os.remove(ref)
    lfs.rmdir(dir .. "/noto")
    lfs.rmdir(dir)
end
