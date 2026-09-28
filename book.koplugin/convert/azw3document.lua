--[[--
AZW3 文档提供者：独立 KF8 先经 convert.kf8 重建成缓存 HTML，再交给 CREngine。
document.file 仍是原 .azw3 路径，书籍身份、进度、sidecar 都按它走。

缓存：cache/azw3/<CACHE_VERSION>_<partialMD5>/info.json 在即命中；解析器产物变了就升 CACHE_VERSION。
非独立 KF8（MOBI6 / MOBI6+KF8 合并文件）info 里没有 html，CREngine 直接按 MOBI 读原文件。
未命中缓存时只探文件头（kf8.probe）：loadDocument(false) 的调用方（书库扫盘、封面浏览、书籍信息）
只要元数据和封面，整本重建推迟到真正打开阅读。

@module koplugin.book.convert.azw3document
--]]

local CreDocument = require("document/credocument")
local Document = require("document/document")
local _ = require("gettext")
require("l10n").apply()

local CACHE_VERSION = "v1"

---@class Azw3Document : CreDocument
---@field azw Kf8Info|table 缓存信息，另带 dir；非独立 KF8 时只有 dir。未重建时是 kf8.probe 结果（无 dir）
local Azw3Document = CreDocument:extend{
    provider = "moon_azw3",
    provider_name = _("AZW3（月读）"),
}

local function cacheDir(file)
    return require("utils.paths").cacheDir() .. "/azw3/" .. CACHE_VERSION .. "_" .. require("util").partialMD5(file)
end

--- 读缓存；未命中返回 nil。
---@param file string
---@return table|nil
function Azw3Document.cached(file)
    local dir = cacheDir(file)
    local f = io.open(dir .. "/info.json", "rb")
    if not f then return nil end
    local info = require("json").decode(f:read("*a"))
    f:close()
    info.dir = dir
    return info
end

--- 取或建缓存；解析失败清掉半成品后原样抛出。
---@param file string
---@return table
function Azw3Document.prepare(file)
    local cached = Azw3Document.cached(file)
    if cached then return cached end
    local JSON = require("json")
    local Paths = require("utils.paths")
    local ffiUtil = require("ffi/util")
    local dir = cacheDir(file)
    local tmp = dir .. ".part"
    ffiUtil.purgeDir(tmp)
    assert(Paths.ensureDir(tmp))
    local ok, info = pcall(require("convert.kf8").extract, file, tmp)
    if not ok then
        ffiUtil.purgeDir(tmp)
        error(info, 0)
    end
    info = info or {}
    local f = assert(io.open(tmp .. "/info.json", "wb"))
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
    -- .azw 可能是 KF8 也可能是 MOBI6；权重需高于 CreDocument 的 90，MOBI6 在 prepare 里原样回落
    registry:addProvider("azw", "application/vnd.amazon.mobi8-ebook", self, 100)
end

function Azw3Document:init()
    self.azw = Azw3Document.cached(self.file) or require("convert.kf8").probe(self.file) or {}
    CreDocument.init(self)
end

--- 重建失败（DRM / HUFF / 结构损坏）返回 false，与 CREngine 加载失败同一语义，由 ReaderUI 提示并关闭。
function Azw3Document:loadDocument(full_document)
    if not self.azw.dir then
        if full_document == false and self.azw.metadata then return true end
        local ok, info = pcall(Azw3Document.prepare, self.file)
        if not ok then
            require("logger").warn("azw3 rebuild failed", self.file, info)
            return false
        end
        self.azw = info
    end
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
--- 未重建时 CREngine 没加载文档，属性只能取 EXTH。
function Azw3Document:getProps(cached_doc_metadata)
    local meta = self.azw.metadata or {}
    local props = Document.getProps(self, cached_doc_metadata or (not self.azw.dir and meta or nil))
    props.title = meta.title or props.title
    props.authors = meta.author or props.authors
    props.language = meta.language or props.language
    props.description = meta.description or props.description
    return props
end

--- 未重建且 EXTH 没有封面时返回 nil：不为一张封面重建整本书。
function Azw3Document:getCoverPageImage()
    local azw = self.azw
    if azw.cover_data then
        return require("ui/renderimage"):renderImageData(azw.cover_data, #azw.cover_data, false)
    end
    if azw.cover then
        local image = require("ui/renderimage"):renderImageFile(azw.dir .. "/" .. azw.cover, false)
        if image then return image end
    end
    if not azw.dir then return nil end
    return CreDocument.getCoverPageImage(self)
end

return Azw3Document
