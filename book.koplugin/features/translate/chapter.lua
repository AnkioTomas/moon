--[[--
章节源的双语对照：按书开关，每章各生成一份双语 HTML。

- 开关存 settings/translate.lua 的 `chapter_bilingual["<source_id>:<stable_id>"] = { engine, lang, unit? }`。
  engine 为 `embed` 时用章节里自带的译文节点，不请求 Edge / AI。
  unit 只在这次翻译选了按句子时写入；缺省按段落。不在设置页里。
- 双语章与整本一样在 `bilingual/<idx>.html`，随清缓存 / 删书一起删；原章更新（mtime 更新）后作废。
  图片和样式表在工作目录，生成时把相对路径改成 `../`。旧的 `<idx>.bi-<engine>-<lang>.html` 只读、不新建。
- 源站嵌在正文里的译文（class `wr-translation`）默认从原章去掉。
  双语稿在 `<idx>.embed.html`：译文收进前一段，class 用 `moon-tr`，原文 xpointer 两版通用。
  打开双语对照且没有现成的生成稿时读这份。
- 开章时双语章已就绪就打开它，否则开原章；翻译只在用户从面板触发时做，走整书同一套
  进度窗 / 转后台 / 完成询问重开（features.translate.bilingual，input.chapter = true）。
- 译文缓存与整书共用 `bilingual/<engine>-<lang>.jsonl`。
- 翻译读落盘后的原章（番茄已解完字体），段评 / 划线定位读原章，见 Paths.chapterOrigin。

@module koplugin.book.features.translate.chapter
--]]

local Markup = require("features.translate.markup")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")

local OWNER = "features.translate"

local ChapterBi = {}

---@param identity BookIdentity
---@return string
local function key(identity)
    return identity.source_id .. ":" .. identity.stable_id
end

--- 本书的双语设置，未开启为 nil。
---@param identity BookIdentity
---@return { engine: "edge"|"ai"|"embed", lang: string }|nil
function ChapterBi.get(identity)
    local map = MoonSettings.get(OWNER).chapter_bilingual
    return map and map[key(identity)]
end

---@param identity BookIdentity
---@param conf { engine: "edge"|"ai"|"embed", lang: string }|nil nil 关闭
function ChapterBi.set(identity, conf)
    local settings = MoonSettings.get(OWNER)
    settings.chapter_bilingual = settings.chapter_bilingual or {}
    settings.chapter_bilingual[key(identity)] = conf
    MoonSettings.save(OWNER)
end

--- 旧文件。当前引擎和语言拼出一个路径，调用方再看它在不在。
---@param path string
---@param conf { engine: string, lang: string }
---@return string
function ChapterBi.legacyPath(path, conf)
    return Paths.legacyBilingualChapterPath(path, conf.engine .. "-" .. conf.lang)
end

--- 读整个文件。没有文件返回 nil。
---@param path string
---@return string|nil
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- 原章带源站译文时，把全文抄到 `.embed.html`，原章只留原文。已经拆过就不动。
--- 先写副本再改原章：中途失败时原文还在。
---@param origin string
---@return string|nil keep 副本路径；这份原章没有译文节点时 nil
function ChapterBi.materialize(origin)
    local html = readFile(origin)
    if not html or not Markup.hasEmbedded(html) then return nil end
    local stripped, bilingual = Markup.splitEmbedded(html)
    if not bilingual then return nil end
    local keep = Paths.embedChapterPath(origin)
    local out = io.open(keep, "wb")
    if not out then return nil end
    local wrote = out:write(bilingual)
    out:close()
    if not wrote then return nil end
    local file = io.open(origin, "wb")
    if not file then return keep end
    file:write(stripped)
    file:close()
    return keep
end

--- 能直接打开的自带译文：副本优先，否则原章自己还带着节点。
---@param origin string
---@return string|nil
function ChapterBi.embedFile(origin)
    local keep = Paths.embedChapterPath(origin)
    if lfs.attributes(keep, "mode") == "file" then return keep end
    local html = readFile(origin)
    if html and Markup.hasEmbedded(html) then return origin end
    return nil
end

--- 当前这本书的双语章路径。没开双语、也没有自带译文副本时是空表。
--- 生成稿在前，旧路径其次，自带译文副本在最后。
---@param identity BookIdentity
---@param origin string 原章
---@return string[]
function ChapterBi.variants(identity, origin)
    local list = {}
    local conf = ChapterBi.get(identity)
    if conf and conf.engine ~= "embed" then
        list[1] = Paths.bilingualChapterPath(origin)
        list[2] = ChapterBi.legacyPath(origin, conf)
    end
    local keep = Paths.embedChapterPath(origin)
    if lfs.attributes(keep, "mode") == "file" then list[#list + 1] = keep end
    return list
end

--- 双语章不比原章旧才算就绪。
---@param origin string
---@param dest string
---@return boolean
local function fresh(origin, dest)
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
        dest = Paths.bilingualChapterPath(origin), dir = dir,
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
    local origin = Paths.chapterOrigin(path)
    local conf = ChapterBi.get(identity)
    if not conf then
        ChapterBi.materialize(origin)
        return nil
    end
    if conf.engine ~= "embed" then
        local dest = Paths.bilingualChapterPath(origin)
        if fresh(origin, dest) then return dest end
        local old = ChapterBi.legacyPath(origin, conf)
        if fresh(origin, old) then return old end
    end
    local keep = Paths.embedChapterPath(origin)
    if lfs.attributes(keep, "mode") ~= "file" then ChapterBi.materialize(origin) end
    if lfs.attributes(keep, "mode") == "file" then return keep end
    return nil
end

return ChapterBi
