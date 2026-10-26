--[[--
生僻字注音词库目录：可下载词库清单、安装 / 删除、按设置加载已启用的词库。

托管与输入法词库相同：仓库 assets/rare/<id>/ 下 manifest.json + 分片，设备经 http.mirror 多源拉取，
下载、校验、落位全走 features.ime.download.install。落盘在 $DATA/.moon/rare/<id>.tsv；
用户自制词库同格式放进这个目录（文件名即 id）也会出现在列表里。

@module koplugin.book.features.rare.catalog
--]]

local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local MoonSettings = require("utils.settings")

local BASE_ROOT = "assets/rare"

local Catalog = {}

--- 内置可下载词库。
---@return { id: string, label: string, lang: string, custom?: boolean }[]
function Catalog.remote()
    return {
        { id = "zh-pinyin", label = _("汉字拼音"), lang = "zh" },
        { id = "en-ipa", label = _("英语音标"), lang = "en" },
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

--- 内置清单 + 目录里用户自放的词库。
---@return { id: string, label: string, lang: string|nil, custom?: boolean }[]
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
        for _idx, id in ipairs(names) do out[#out + 1] = { id = id, label = id, custom = true } end
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

--- 已启用且已安装的词库。
---@return RareLexicon[]
function Catalog.active()
    local out = {}
    for id, on in pairs(MoonSettings.get("features.rare").rare_lexicons) do
        if on then
            local lex = Catalog.load(id)
            if lex then out[#out + 1] = lex end
        end
    end
    return out
end

---@param id string
---@param on boolean
function Catalog.setEnabled(id, on)
    local s = MoonSettings.get("features.rare")
    s.rare_lexicons[id] = on or nil
    MoonSettings.save("features.rare", s)
end

---@param id string
---@return boolean
function Catalog.enabled(id)
    return MoonSettings.get("features.rare").rare_lexicons[id] == true
end

--- 下载规格：装好后自动启用。
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
            s.rare_lexicons[id] = true
            MoonSettings.save("features.rare", s)
            loaded[id] = nil
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
