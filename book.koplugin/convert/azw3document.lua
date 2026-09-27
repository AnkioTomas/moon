--[[--
AZW3 文档提供者：独立 KF8 先经 convert.kf8 重建成缓存 HTML，再交给 CREngine。
document.file 仍是原 .azw3 路径，书籍身份、进度、sidecar 都按它走。

缓存：cache/azw3/<CACHE_VERSION>_<partialMD5>/info.json 在即命中；解析器产物变了就升 CACHE_VERSION。
非独立 KF8（MOBI6 / MOBI6+KF8 合并文件）info 里没有 html，CREngine 直接按 MOBI 读原文件。

@module koplugin.book.convert.azw3document
--]]

local CreDocument = require("document/credocument")
local Document = require("document/document")
local _ = require("gettext")
require("l10n").apply()

local CACHE_VERSION = "v1"

---@class Azw3Document : CreDocument
---@field azw Kf8Info|table 缓存信息，另带 dir；非独立 KF8 时只有 dir
local Azw3Document = CreDocument:extend{
    provider = "moon_azw3",
    provider_name = _("AZW3（月读）"),
}

--- 取或建缓存；解析失败清掉半成品后原样抛出。
---@param file string
---@return table
function Azw3Document.prepare(file)
    local JSON = require("json")
    local Paths = require("utils.paths")
    local ffiUtil = require("ffi/util")
    local dir = Paths.cacheDir() .. "/azw3/" .. CACHE_VERSION .. "_" .. require("util").partialMD5(file)
    local f = io.open(dir .. "/info.json", "rb")
    if f then
        local info = JSON.decode(f:read("*a"))
        f:close()
        info.dir = dir
        return info
    end
    local tmp = dir .. ".part"
    ffiUtil.purgeDir(tmp)
    assert(Paths.ensureDir(tmp))
    local ok, info = pcall(require("convert.kf8").extract, file, tmp)
    if not ok then
        ffiUtil.purgeDir(tmp)
        error(info, 0)
    end
    info = info or {}
    f = assert(io.open(tmp .. "/info.json", "wb"))
    assert(f:write(JSON.encode(info)))
    assert(f:close())
    ffiUtil.purgeDir(dir)
    assert(os.rename(tmp, dir))
    info.dir = dir
    return info
end

--- 注册到 DocumentRegistry；FM 与 Reader 各初始化一次插件，重复注册会在「打开方式」里出现两项。
---@param registry table
function Azw3Document:register(registry)
    if registry:getProviderFromKey(self.provider) then return end
    registry:addProvider("azw3", "application/vnd.amazon.mobi8-ebook", self, 100)
end

function Azw3Document:init()
    self.azw = Azw3Document.prepare(self.file)
    CreDocument.init(self)
end

function Azw3Document:loadDocument(full_document)
    if not self.azw.html then
        return CreDocument.loadDocument(self, full_document)
    end
    if not self._loaded then
        self._loaded = self._document:loadDocument(self.azw.dir .. "/" .. self.azw.html, full_document == false)
    end
    return self._loaded
end

--- NCX 目录：锚点在 CREngine 建好 DOM 后才能解析成页码；解析不到的沿用上一项页码，保持单调。
function Azw3Document:getToc()
    local items = self.azw.toc
    if not items or #items == 0 then
        return CreDocument.getToc(self)
    end
    local toc, last = {}, 1
    for _, item in ipairs(items) do
        local page = self:isXPointerInDocument(item.anchor) and self:getPageFromXPointer(item.anchor) or last
        if page < last then page = last end
        last = page
        toc[#toc + 1] = { title = item.title, depth = item.depth, page = page, xpointer = item.anchor }
    end
    return toc
end

--- 覆盖 getProps 而不是 getDocumentProps：CreDocument:setupCallCache 把基类 get* 包好直接挂在实例上，
--- 子类的 getDocumentProps 永远调不到；getProps 继承自 Document，不在包装范围内。
function Azw3Document:getProps(cached_doc_metadata)
    local props = Document.getProps(self, cached_doc_metadata)
    local meta = self.azw.metadata or {}
    props.title = meta.title or props.title
    props.authors = meta.author or props.authors
    props.language = meta.language or props.language
    props.description = meta.description or props.description
    return props
end

function Azw3Document:getCoverPageImage()
    if self.azw.cover then
        local image = require("ui/renderimage"):renderImageFile(self.azw.dir .. "/" .. self.azw.cover, false)
        if image then return image end
    end
    return CreDocument.getCoverPageImage(self)
end

return Azw3Document
