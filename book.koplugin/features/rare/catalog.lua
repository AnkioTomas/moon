--[[--
生僻字注音 / WordWise 释义词库目录：可下载词库清单、安装 / 删除、按设置加载已启用的词库。

托管与输入法词库相同：仓库 assets/rare/<id>/ 下 manifest.json + 分片，设备经 http.mirror 多源拉取，
下载、校验、落位全走 features.ime.download.install。落盘在 $DATA/.moon/rare/<id>.tsv；
用户自制词库同格式放进这个目录（文件名即 id）也会出现在列表里。

对齐 Kindle：注音（中文拼音 / 英语 IPA）与 WordWise 释义可同时启用——按文字类型分流
（汉字走 zh 词库、英文词走 en 词库），同 span 重叠时 overlay 里 wordwise 优先于 ruby。
仅两份英文释义词库互斥（对标 Kindle Word Wise 的 Language）。

@module koplugin.book.features.rare.catalog
--]]

local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")

local BASE_ROOT = "assets/rare"

local Catalog = {}

--- 内置可下载词库。
---@return { id: string, label: string, lang: string, kind: string, custom?: boolean }[]
function Catalog.remote()
    return {
        { id = "zh-pinyin", label = _("汉字拼音"), lang = "zh", kind = "ruby" },
        { id = "en-ipa", label = _("英语音标"), lang = "en", kind = "ruby" },
        { id = "en-gloss-zh", label = _("英语释义（中文）"), lang = "en", kind = "wordwise" },
        { id = "en-gloss-en", label = _("英语释义（英文）"), lang = "en", kind = "wordwise" },
    }
end

---@return string
function Catalog.dir()
    return Paths.root() .. "/rare"
end

---@param id string
---@return string
function Catalog.path(id)
    return Catalog.dir() .. "/" .. id .. ".tsv"
end

---@param id string
---@return boolean
function Catalog.installed(id)
    return lfs.attributes(Catalog.path(id), "mode") == "file"
end

--- 内置清单项的 kind；未知 id 返回 nil（再读文件）。
---@param id string
---@return string|nil
local function remoteKind(id)
    for _idx, item in ipairs(Catalog.remote()) do
        if item.id == id then return item.kind end
    end
end

--- 词库显示类型：内置清单优先，否则读文件 #kind，缺省 ruby。
---@param id string
---@return "ruby"|"wordwise"
function Catalog.kind(id)
    local known = remoteKind(id)
    if known then return known end
    local lex = Catalog.load(id)
    if lex then return lex.kind end
    return "ruby"
end

--- 内置清单 + 目录里用户自放的词库。
---@return { id: string, label: string, lang: string|nil, kind: string, custom?: boolean }[]
function Catalog.list()
    local out, seen = {}, {}
    for _idx, item in ipairs(Catalog.remote()) do
        out[#out + 1] = item
        seen[item.id] = true
    end
    if lfs.attributes(Catalog.dir(), "mode") == "directory" then
        local names = {}
        for f in lfs.dir(Catalog.dir()) do
            local id = f:match("^([%w_%-]+)%.tsv$")
            if id and not seen[id] then names[#names + 1] = id end
        end
        table.sort(names)
        for _idx, id in ipairs(names) do
            out[#out + 1] = { id = id, label = id, kind = Catalog.kind(id), custom = true }
        end
    end
    return out
end

-- id → { lex = RareLexicon, mtime = number }
local loaded = {}

--- 读入并缓存一个已装词库；文件变了（重新下载）就重读。坏文件抛错，由调用方入口 guard 兜住。
---@param id string
---@return RareLexicon|nil 未安装时 nil
function Catalog.load(id)
    local path = Catalog.path(id)
    local mtime = lfs.attributes(path, "modification")
    if not mtime then
        loaded[id] = nil
        return nil
    end
    local cached = loaded[id]
    if cached and cached.mtime == mtime then return cached.lex end
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    local lex = require("features.rare.lexicon").parse(text)
    loaded[id] = { lex = lex, mtime = mtime }
    return lex
end

--- 已启用且已安装、且对应类型开关开着的词库（重叠由 overlay 消解）。
---@return RareLexicon[]
function Catalog.active()
    local Rare = require("features.rare")
    local s = Rare.migrate()
    local out = {}
    for id, on in pairs(s.rare_lexicons) do
        if on then
            local lex = Catalog.load(id)
            if lex and Rare.kindOn(lex.kind, s) then out[#out + 1] = lex end
        end
    end
    return out
end

--- 主进程预载已启用词库。翻页 Job 会 fork：子进程 COW 继承这份哈希，避免每页重 parse 整份 TSV（WordWise ~1MB）。
---@return integer 本次新加载（或因文件更新而重载）的份数
function Catalog.warm()
    local n = 0
    for id, on in pairs(MoonSettings.get("features.rare").rare_lexicons) do
        if on then
            local mtime = lfs.attributes(Catalog.path(id), "modification")
            local cached = loaded[id]
            if mtime and not (cached and cached.mtime == mtime) then
                Catalog.load(id)
                n = n + 1
            end
        end
    end
    return n
end

--- 启用释义词库时关掉另一份释义（Kindle Word Wise Language 单选）。
---@param s table
---@param keep_id string
local function disableOtherWordwise(s, keep_id)
    for id, on in pairs(s.rare_lexicons) do
        if on and id ~= keep_id and Catalog.kind(id) == "wordwise" then
            s.rare_lexicons[id] = nil
        end
    end
end

---@param id string
---@param on boolean
function Catalog.setEnabled(id, on)
    local s = MoonSettings.get("features.rare")
    if on then
        if Catalog.kind(id) == "wordwise" then
            disableOtherWordwise(s, id)
        end
        s.rare_lexicons[id] = true
        MoonSettings.save("features.rare", s)
        -- 启用当场预载，别把 parse 留到第一次翻页。
        Catalog.load(id)
    else
        s.rare_lexicons[id] = nil
        MoonSettings.save("features.rare", s)
    end
end

---@param id string
---@return boolean
function Catalog.enabled(id)
    return MoonSettings.get("features.rare").rare_lexicons[id] == true
end

--- 下载规格：装好后经 setEnabled 启用。
---@param id string
---@return BookDictSpec
function Catalog.spec(id)
    return {
        name = "rare." .. id,
        base_path = BASE_ROOT .. "/" .. id,
        dest = Catalog.path(id),
        installed = MoonSettings.get("features.rare").rare_built_at[id],
        on_installed = function(manifest)
            local s = MoonSettings.get("features.rare")
            s.rare_built_at[id] = manifest.built_at
            MoonSettings.save("features.rare", s)
            loaded[id] = nil
            Catalog.setEnabled(id, true)
        end,
    }
end

--- 下载 / 更新，装好后自动启用。
---@param id string
---@param cb fun(ok: boolean, err: any)
---@param on_progress function|nil
function Catalog.download(id, cb, on_progress)
    Paths.ensureDir(Catalog.dir())
    require("features.ime.download").install(Catalog.spec(id), cb, on_progress)
end

--- 删掉词库文件与记录。
---@param id string
function Catalog.delete(id)
    os.remove(Catalog.path(id))
    loaded[id] = nil
    local s = MoonSettings.get("features.rare")
    s.rare_lexicons[id], s.rare_built_at[id] = nil, nil
    MoonSettings.save("features.rare", s)
end

return Catalog
