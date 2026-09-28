--[[-- convert.azw3document：缓存、CREngine 加载路径、目录 / 元数据 / 封面、注册去重 --]]

local Assert = require("support.assert")
local Fixture = require("support.kf8_fixture")
local Config = require("support.config")
local Json = require("support.json_stub")

package.preload["json"] = function() return { encode = Json.encode, decode = Json.decode } end
package.loaded["util"] = nil
package.preload["util"] = function()
    return { partialMD5 = function(path) return (path:match("([^/]+)%.azw3$")) end }
end
package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function(_, path) return "image:" .. path end,
        renderImageData = function(_, data, size) return "data:" .. size .. ":" .. data end,
    }
end

local loads, pages = {}, {}
package.preload["document/document"] = function()
    local Document = {}
    function Document:getProps(cached)
        local p = cached or self:getDocumentProps()
        local function nilIfEmpty(s) return s ~= "" and s or nil end
        return { title = nilIfEmpty(p.title), authors = nilIfEmpty(p.authors), language = nilIfEmpty(p.language) }
    end
    return Document
end
package.preload["document/credocument"] = function()
    local Cre = setmetatable({}, { __index = require("document/document") })
    function Cre:extend(o) return setmetatable(o or {}, { __index = self }) end
    function Cre:init()
        self._document = { loadDocument = function(_, path, only_metadata)
            loads[#loads + 1] = { path = path, only_metadata = only_metadata }
            return true
        end }
        -- 同 CreDocument:setupCallCache：基类 get* 包好挂到实例上，遮住子类覆盖
        self.getDocumentProps = function(doc) return Cre.getDocumentProps(doc) end
    end
    function Cre:loadDocument(full) return self._document:loadDocument(self.file, full == false) end
    function Cre:getToc() return { { title = "cre" } } end
    function Cre:getDocumentProps() return { title = "cre-title", authors = "", language = "en" } end
    function Cre:getCoverPageImage() return "cre-cover" end
    function Cre:isXPointerInDocument(xp) return pages[xp] ~= nil end
    function Cre:getPageFromXPointer(xp) return pages[xp] end
    return Cre
end
package.loaded["document/document"] = nil
package.loaded["document/credocument"] = nil
package.loaded["convert.azw3document"] = nil
package.loaded["convert.kf8"] = nil

local Azw3Document = require("convert.azw3document")
local Kf8 = require("convert.kf8")
local cache_root = require("utils.paths").cacheDir() .. "/azw3"
local root = Config.dir() .. "/azw3document_spec"
os.execute("rm -rf '" .. root .. "' '" .. cache_root .. "' && mkdir -p '" .. root .. "'")

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function open(name, opts)
    local book = root .. "/" .. name .. ".azw3"
    if opts then Fixture.write(book, opts) end
    local doc = setmetatable({ file = book }, { __index = Azw3Document })
    doc:init()
    return doc
end

local calls = 0
local real_extract = Kf8.extract
Kf8.extract = function(...) calls = calls + 1; return real_extract(...) end

-- 首次打开只取元数据（扫盘 / 封面浏览）：只探文件头，不重建、不落缓存、不动 CREngine
do
    local doc = open("kf8", { compression = 2 })
    local dir = cache_root .. "/v1_kf8"
    Assert.is_true(doc:loadDocument(false))
    Assert.eq(calls, 0)
    Assert.len(loads, 0)
    Assert.is_false(exists(dir))
    local props = doc:getProps()
    Assert.eq(props.title, Fixture.TITLE)
    Assert.eq(props.authors, Fixture.AUTHOR)
    Assert.eq(doc:getCoverPageImage(), "data:13:\255\216\255\224fake-jpeg")
    Assert.eq(calls, 0, "取封面不触发重建")
end

-- 真正打开阅读：重建并落缓存；CREngine 读缓存 HTML
do
    local doc = open("kf8")
    local dir = cache_root .. "/v1_kf8"
    Assert.is_true(doc:loadDocument())
    Assert.eq(calls, 1)
    Assert.eq(doc.azw.dir, dir)
    Assert.is_true(exists(dir .. "/info.json"))
    Assert.is_true(exists(dir .. "/book.html"))
    Assert.is_false(exists(dir .. ".part"), "临时目录已改名")
    Assert.eq(loads[#loads].path, dir .. "/book.html")
    Assert.is_false(loads[#loads].only_metadata)
    doc:loadDocument()
    Assert.len(loads, 1, "已加载不重复加载")

    local props = doc:getProps()
    Assert.eq(props.title, Fixture.TITLE)
    Assert.eq(props.authors, Fixture.AUTHOR, "CREngine 读不到 HTML 作者，由 EXTH 补上")
    Assert.eq(props.language, "en", "EXTH 没有的字段保留 CREngine 值")
    Assert.eq(doc:getProps({ title = "cached", authors = "" }).authors, Fixture.AUTHOR, "缓存元数据同样补齐")
    Assert.eq(doc:getCoverPageImage(), "image:" .. dir .. "/res0001.jpg")
end

-- 再次打开：命中缓存，不再解析；只取元数据时 CREngine 按元数据模式读缓存 HTML
do
    loads = {}
    local doc = open("kf8")
    Assert.eq(calls, 1)
    Assert.len(doc.azw.toc, 3)
    Assert.is_true(doc:loadDocument(false))
    Assert.eq(loads[1].path, cache_root .. "/v1_kf8/book.html")
    Assert.is_true(loads[1].only_metadata)

    -- 目录：解析不到的锚点沿用上一项页码，页码不回退
    pages = { ["#azwfid0000"] = 3, ["#azwfid0001"] = 2 }
    local toc = doc:getToc()
    Assert.len(toc, 3)
    Assert.eq(toc[1].page, 3)
    Assert.eq(toc[1].xpointer, "#azwfid0000")
    Assert.eq(toc[2].title, "第一节")
    Assert.eq(toc[2].depth, 2)
    Assert.eq(toc[3].page, 3, "页码不回退")
    pages = { ["#azwfid0001"] = 7 }
    toc = doc:getToc()
    Assert.eq(toc[1].page, 1, "解析不到时从第 1 页起")
    Assert.eq(toc[3].page, 7)
end

-- MOBI6 / 合并文件：记下不走重建，CREngine 直读原文件，其余走 CREngine 默认
do
    loads = {}
    local doc = open("mobi6", { version = 6 })
    Assert.eq(calls, 1, "探头认出非独立 KF8，打开时不解析")
    doc:loadDocument(false)
    Assert.eq(calls, 2)
    Assert.is_nil(doc.azw.html)
    Assert.eq(loads[1].path, root .. "/mobi6.azw3")
    Assert.is_true(loads[1].only_metadata)
    Assert.eq(doc:getToc()[1].title, "cre")
    Assert.eq(doc:getProps().title, "cre-title")
    Assert.is_nil(doc:getProps().authors)
    Assert.eq(doc:getCoverPageImage(), "cre-cover")
    open("mobi6"):loadDocument()
    Assert.eq(calls, 2, "直读结论同样缓存")
end

-- 重建失败（DRM）：元数据照常可取；完整加载返回 false，清掉半成品，下次仍会重试
do
    local doc = open("drm", { encryption = 2 })
    Assert.is_true(doc:loadDocument(false))
    Assert.eq(doc:getProps().title, Fixture.TITLE)
    Assert.is_false(doc:loadDocument())
    Assert.is_false(exists(cache_root .. "/v1_drm.part"))
    Assert.is_false(exists(cache_root .. "/v1_drm"))
    Assert.is_false(open("drm"):loadDocument())
    Assert.eq(calls, 4)
end

-- 结构损坏（不是 BOOKMOBI）：打开即失败，同 DocumentRegistry 的「无法打开」
do
    local bad = root .. "/bad.azw3"
    local f = assert(io.open(bad, "wb"))
    f:write("not a book")
    f:close()
    Assert.errors(function() open("bad") end, "BOOKMOBI")
end

-- 注册：FM 与 Reader 各调一次，只登记一项
do
    local added = {}
    local registry = {
        known = {},
        getProviderFromKey = function(self, key) return self.known[key] end,
        addProvider = function(self, ext, mime, provider, weight)
            added[#added + 1] = { ext = ext, weight = weight }
            self.known[provider.provider] = provider
        end,
    }
    Azw3Document:register(registry)
    Azw3Document:register(registry)
    Assert.len(added, 2)
    Assert.eq(added[1].ext, "azw3")
    Assert.eq(added[2].ext, "azw")
    Assert.is_true(added[2].weight > 90, "azw 需压过 CreDocument 的 90")
end

Kf8.extract = real_extract
os.execute("rm -rf '" .. root .. "' '" .. cache_root .. "'")
return true
