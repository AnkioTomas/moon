--[[--
章节源的双语对照：按书开关，每章各生成一份双语 HTML。

- 开关存 settings/translate.lua 的 `chapter_bilingual["<source_id>:<stable_id>"] = { engine, lang }`。
- 双语章与整本一样在 `bilingual/<idx>.html`，随清缓存 / 删书一起删；原章更新（mtime 更新）后作废。
  图片和样式表在工作目录，生成时把相对路径改成 `../`。旧的 `<idx>.bi-<engine>-<lang>.html` 只读、不新建。
- 开章时双语章已就绪就打开它，否则开原章；翻译只在用户从面板触发时做，走整书同一套
  进度窗 / 转后台 / 完成询问重开（features.translate.bilingual，input.chapter = true）。
- 译文缓存与整书共用 `bilingual/<engine>-<lang>.jsonl`。
- 翻译读落盘后的原章（番茄已解完字体），段评 / 划线定位读原章，见 Paths.chapterOrigin。

@module koplugin.book.features.translate.chapter
--]]

local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")

local OWNER = "features.translate"

local ChapterBi = {}

---@param identity BookIdentity
---@return string
local function key(identity)
    return identity.source_id .. ":" .. identity.stable_id
end

--- 本书的双语设置，未开启为 nil。
---@param identity BookIdentity
---@return { engine: "edge"|"ai", lang: string }|nil
function ChapterBi.get(identity)
    local map = MoonSettings.get(OWNER).chapter_bilingual
    return map and map[key(identity)]
end

---@param identity BookIdentity
---@param conf { engine: "edge"|"ai", lang: string }|nil nil 关闭
function ChapterBi.set(identity, conf)
    local settings = MoonSettings.get(OWNER)
    settings.chapter_bilingual = settings.chapter_bilingual or {}
    settings.chapter_bilingual[key(identity)] = conf
    MoonSettings.save(OWNER)
end

---@param path string
---@param conf { engine: string, lang: string }
---@return string
function ChapterBi.pathFor(path, _conf)
    return Paths.bilingualChapterPath(path)
end

--- 旧文件。当前引擎和语言拼出一个路径，调用方再看它在不在。
---@param path string
---@param conf { engine: string, lang: string }
---@return string
function ChapterBi.legacyPath(path, conf)
    return Paths.legacyBilingualChapterPath(path, conf.engine .. "-" .. conf.lang)
end

--- 当前这本书的双语章路径。没开双语就是空表。新路径在前，旧路径在后，都是算出来的。
---@param identity BookIdentity
---@param origin string 原章
---@return string[]
function ChapterBi.variants(identity, origin)
    local conf = ChapterBi.get(identity)
    if not conf then return {} end
    return { ChapterBi.pathFor(origin), ChapterBi.legacyPath(origin, conf) }
end

--- 双语章不比原章旧才算就绪。
---@param origin string
---@param dest string
---@return boolean
local function fresh(origin, dest)
    local lfs = require("libs/libkoreader-lfs")
    local a, b = lfs.attributes(dest, "modification"), lfs.attributes(origin, "modification")
    return a ~= nil and b ~= nil and a >= b
end

--- 整书翻译任务的输入（单章 HTML，原章不删、不写 meta）。
---@param identity BookIdentity
---@param origin string 原章
---@param conf { engine: "edge"|"ai", lang: string }
---@return BilingualInput
function ChapterBi.input(identity, origin, conf)
    local dir = Paths.bookWorkDir(identity.stable_id, identity.source_id) .. "/" .. require("features.translate.bilingual").DIR
    assert(Paths.ensureDir(dir))
    return {
        kind = "dom", chapter = true, origin = origin, source = origin,
        dest = ChapterBi.pathFor(origin, conf), dir = dir,
        cache = dir .. "/" .. conf.engine .. "-" .. conf.lang .. ".jsonl",
        engine = conf.engine, lang = conf.lang,
    }
end

--- Chapter.variant 实现：本书开着双语且本章双语章就绪时返回它，否则 nil（开原章）。
---@param identity BookIdentity
---@param _idx integer
---@param path string 原章
---@return string|nil
function ChapterBi.resolve(identity, _idx, path)
    local conf = ChapterBi.get(identity)
    if not conf then return nil end
    local dest = ChapterBi.pathFor(path)
    if fresh(path, dest) then return dest end
    local old = ChapterBi.legacyPath(path, conf)
    return fresh(path, old) and old or nil
end

return ChapterBi
