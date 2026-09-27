--[[-- OPDS 书城编排：翻页收集、搜索模板解析、错误文案、下载导入。 @module tests.opds.init_spec --]]

local Assert = require("support.assert")

local ROOT = "http://nas/opds"

--- 拼一份最小 Atom feed。
---@param opts { entries?: string[], next?: string, extra?: string }
local function atom(opts)
    local parts = { "<feed>" }
    if opts.next then parts[#parts + 1] = '<link rel="next" href="' .. opts.next .. '" type="application/atom+xml"/>' end
    parts[#parts + 1] = opts.extra or ""
    for _, e in ipairs(opts.entries or {}) do parts[#parts + 1] = e end
    parts[#parts + 1] = "</feed>"
    return table.concat(parts)
end

local function bookEntry(n)
    return '<entry><title>B' .. n .. '</title><id>id' .. n .. '</id>'
        .. '<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/dl/' .. n .. '"/>'
        .. '<link rel="http://opds-spec.org/image/thumbnail" href="/cover/' .. n .. '"/></entry>'
end

local responses, requested = {}, {}
local cfg = { url = ROOT }
local fake = {}
function fake:rootUrl() return cfg.url or "" end
function fake:configured() return (cfg.url or "") ~= "" end
function fake:coverHeaders(url) return url and { Authorization = "x" } or nil end
function fake:getAsync(url, cb)
    requested[#requested + 1] = url
    local r = responses[url]
    if type(r) == "table" then cb(nil, "HTTP " .. r.code, r) else cb(r, r == nil and "missing" or nil) end
    return { cancel = function() end }
end
function fake:downloadAsync(url, dest, _, cb)
    fake.download = { url, dest }
    local f = io.open(dest, "wb")
    f:write(fake.payload or "PK\3\4")
    f:close()
    if fake.defer then fake.download_cb = cb else cb(true) end
    return { cancel = function() fake.download_cancelled = true end }
end

local sandbox = require("support.config").dir() .. "/opds-init-spec"
os.execute("mkdir -p '" .. sandbox .. "'")
package.preload["opds.client"] = function() return { new = function() return fake end } end
package.preload["json"] = function() return { decode = require("support.json_stub").decode } end
package.loaded["json"] = nil
package.loaded["opds.mapper"] = nil
package.preload["utils.settings"] = function() return { getSource = function() return cfg end } end
package.preload["utils.paths"] = function()
    return { ensureBookWork = function() end, bookWorkDir = function() return sandbox end }
end
package.loaded["opds.init"] = nil
local Opds = require("opds.init")

local result, err
local function list(opts)
    result, err = nil, nil
    requested = {}
    Opds:listStoreAsync(opts, function(v, e) result, err = v, e end)
end

-- 顺 next 翻页收集；next 成环时停下，不无限请求。
responses[ROOT] = atom{ entries = { bookEntry(1), bookEntry(2) }, next = "/opds?p=2" }
responses[ROOT .. "?p=2"] = atom{ entries = { bookEntry(3) }, next = "/opds" }
list({ page_size = 200 })
Assert.len(result.data, 3)
Assert.eq(result.count, 3)
Assert.len(requested, 2)
Assert.eq(result.data[3].title, "B3")
Assert.eq(result.data[1].cover_headers.Authorization, "x")

-- 凑满 page_size 就不再翻页。
list({ page_size = 2 })
Assert.len(result.data, 2)
Assert.len(requested, 1)

-- 下钻：传入 feed 即请求该地址。
responses["http://nas/opds/new"] = atom{ entries = { bookEntry(9) } }
list({ feed = "http://nas/opds/new" })
Assert.eq(requested[1], "http://nas/opds/new")
Assert.eq(result.data[1].title, "B9")

-- 搜索：根目录直接给模板。
responses[ROOT] = atom{ extra = '<link rel="search" type="application/atom+xml" href="/opds/search/{searchTerms}"/>' }
responses["http://nas/opds/search/lua%20x"] = atom{ entries = { bookEntry(5) } }
list({ search = " lua x ", feed = "http://nas/opds/new" })
Assert.eq(requested[1], ROOT)
Assert.eq(requested[2], "http://nas/opds/search/lua%20x")
Assert.eq(result.data[1].title, "B5")

-- 搜索：只有 OpenSearch 描述。
responses[ROOT] = atom{ extra = '<link rel="search" type="application/opensearchdescription+xml" href="/osd"/>' }
responses["http://nas/osd"] = '<OpenSearchDescription><Url type="application/atom+xml" template="/s?q={searchTerms}&amp;p={startPage?}"/></OpenSearchDescription>'
responses["http://nas/s?q=abc&p="] = atom{ entries = { bookEntry(6) } }
list({ search = "abc" })
Assert.eq(requested[3], "http://nas/s?q=abc&p=")
Assert.eq(result.data[1].title, "B6")

-- OPDS 2.0：根目录 JSON 给 RFC 6570 模板，结果也是 JSON。
responses[ROOT] = '{"metadata":{"title":"v2"},"links":[{"rel":"search","templated":true,'
    .. '"href":"/v2/search{?query}","type":"application/opds+json"}]}'
responses["http://nas/v2/search?query=abc"] = '{"metadata":{"title":"r"},"publications":[{"metadata":'
    .. '{"identifier":"v2-1","title":"V2 Book"},"links":[{"rel":"http://opds-spec.org/acquisition",'
    .. '"href":"/dl/v2.epub","type":"application/epub+zip"}]}]}'
list({ search = "abc" })
Assert.eq(requested[2], "http://nas/v2/search?query=abc")
Assert.eq(result.data[1].stable_id, "v2-1")
Assert.eq(result.data[1].download, "http://nas/dl/v2.epub")

-- 不支持搜索 / 认证失败 / 非 Atom。
responses[ROOT] = atom{}
list({ search = "abc" })
Assert.is_nil(result)
Assert.eq(err, "该 OPDS 目录不支持搜索")
responses[ROOT] = { code = 401 }
list({})
Assert.eq(err, "OPDS 认证失败，请检查用户名和密码")
responses[ROOT] = "<html>login</html>"
list({})
Assert.eq(err, "不是有效的 OPDS 目录")

-- 未配置不发请求。
cfg.url = nil
list({})
Assert.eq(err, "未配置 OPDS 目录")
Assert.len(requested, 0)
cfg.url = ROOT

-- 下载后导入，文件名 = 书名 - 作者.格式。
local imported
local source = {
    importBookAsync = function(_, path, filename, cb)
        imported = { path, filename }
        cb(true)
        return { cancel = function() end }
    end,
}
local book = { source_id = "opds", stable_id = "id1", title = "书/名", authors = "作者",
    download = "http://nas/dl/1", format = "epub" }
local installed
Opds.installAsync(source, book, nil, function(ok, e, filename) installed = { ok, e, filename } end)
Assert.eq(fake.download[1], "http://nas/dl/1")
Assert.eq(imported[2], "书_名 - 作者.epub")
Assert.eq(imported[1], sandbox .. "/书_名 - 作者.epub")
Assert.is_true(installed[1])
Assert.eq(installed[3], "书_名 - 作者.epub")

-- 服务端回 200 登录页：不导入，删临时文件。
imported = nil
fake.payload = "  <!DOCTYPE html><html>"
Opds.installAsync(source, book, nil, function(ok, e) installed = { ok, e } end)
Assert.is_nil(imported)
Assert.is_nil(installed[1])
Assert.eq(installed[2], "下载内容不是书籍文件")
Assert.is_nil(io.open(fake.download[2], "rb"))
fake.payload = nil

-- 没有可用格式直接失败，不发请求。
fake.download = nil
Opds.installAsync(source, { stable_id = "x", title = "t" }, nil, function(ok, e) installed = { ok, e } end)
Assert.is_nil(fake.download)
Assert.eq(installed[2], "没有本地书库支持的下载格式")

-- 导入阶段取消：取消导入任务并删临时文件。
fake.defer = true
local import_cancelled = false
local job = Opds.installAsync({
    importBookAsync = function() return { cancel = function() import_cancelled = true end } end,
}, book, nil, function() end)
fake.download_cb(true)
job.cancel()
Assert.is_true(import_cancelled)
Assert.is_nil(io.open(fake.download[2], "rb"))
fake.defer = false

os.execute("rm -rf '" .. sandbox .. "'")
