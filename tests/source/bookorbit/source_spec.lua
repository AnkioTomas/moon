--[[--
extensions/moonsource-bookorbit.koplugin：经源注册表发现；书架（按库分页、库名分类、空库保护）、
开书（挑格式、下载、失败清理）、封面、详情、kosync 进度双向、划线上传。HTTP 与书库全部打桩。

@module tests.source.bookorbit.source_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local Themed = require("support.theme_stubs")

-- 往返桩：encode 登记表并发一个令牌串，decode 凭令牌取回（不是令牌就报错，同真解析器）。
local encoded = {}
local ARRAY = {}
-- decode 同 LuaJSON 是可调用表，带 simple 模式（null → nil）。
local SIMPLE = {}
local decode_mode
local JSON = {
    encode = function(value)
        encoded[#encoded + 1] = value
        return "\0json" .. #encoded
    end,
    decode = setmetatable({ simple = SIMPLE }, { __call = function(_self, text, mode)
        decode_mode = mode
        return encoded[tonumber(text:match("^%z?json(%d+)$"))] or error("not json: " .. text)
    end }),
    util = { InitArray = function(t) return setmetatable(t, ARRAY) end },
}
package.loaded["json"] = JSON
Themed.install()
local PLUGIN = Config.root() .. "/book.koplugin/source/bookorbit"
-- 走 preload 不改 package.path：runner 只还原 preload/loaded，插件根上的 main.lua 会顶掉月读的 main。
for _idx, name in ipairs({ "client", "source", "setting" }) do
    package.preload["source.bookorbit" .. (name == "source" and "" or "." .. name)] = function()
        return dofile(PLUGIN .. "/" .. (name == "source" and "init" or name) .. ".lua")
    end
end

local cfg = { server_url = " http://bo/api/v1/ ", username = " ann ", userkey = "k" }
local saved_cfg
package.preload["utils.settings"] = function()
    local common = { active_source = "local" }
    return {
        get = function() return common end,
        save = function() end,
        getSource = function() return cfg end,
        saveSource = function(_id, value) saved_cfg = value end,
    }
end
for _idx, id in ipairs({ "local", "moon", "wechat", "jdread", "copymanga", "fanqie" }) do
    package.loaded["source." .. id] = {
        meta = function() return { id = id, name = id, type = "book" } end,
        new = function() return { id = id } end,
    }
end

local online = true
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
_G.G_reader_settings = { readSetting = function(_self, key) return key == "device_id" and "dev-1" or nil end }
package.loaded["device"] = { model = "Kindle" }
package.loaded["util"] = { partialMD5 = function(path) return path:match("/1/12%.epub$") and ("a"):rep(32) or ("b"):rep(32) end }

-- HTTP：按 "METHOD /path" 路由；值为响应表或 fun(opts) → 响应表。
local routes, calls = {}, {}
local download = { code = 200, body = "PK\3\4epub" }
package.loaded["http.request"] = {
    ok = function(code)
        code = tonumber(code)
        return code ~= nil and code >= 200 and code < 300
    end,
    request = function(opts, cb)
        calls[#calls + 1] = opts
        local route = routes[opts.method .. " " .. opts.url:match("^http://bo/api/v1(/[^?]*)")]
        require("ui/uimanager"):nextTick(function()
            cb(type(route) == "function" and route(opts) or route or { code = 404, body = "" })
        end)
        return { cancel = function() end }
    end,
    download = function(opts, dest, cb)
        calls[#calls + 1] = opts
        local file = assert(io.open(dest, "wb"))
        file:write(download.body)
        file:close()
        require("ui/uimanager"):nextTick(function() cb(true, nil, { code = download.code }) end)
        return { cancel = function() end }
    end,
}
local function json(data) return { code = 200, body = JSON.encode(data) } end
local function query(opts, key) return opts.url:match("[?&]" .. key .. "=([^&]*)") end

local books, progress, remembered, touched, reconciled = {}, {}, {}, {}, nil
package.loaded["book.books_db"] = { get = function(_sid, id) return books[id] end }
package.loaded["book.progress_db"] = { get = function(_sid, id) return progress[id] end }
package.loaded["book.store"] = {
    touch = function(path, ref)
        touched[#touched + 1] = { path = path, stable_id = ref.stable_id }
        books[ref.stable_id] = { path = path }
        return true
    end,
    rememberMany = function(list)
        for _idx, book in ipairs(list) do remembered[book.stable_id] = book end
    end,
}
package.loaded["source.shelf"] = {
    reconcile = function(source_id, list)
        reconciled = { source_id = source_id, books = list }
        return { pulled = #list, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    end,
}
local WORK = Config.dir() .. "/bookorbit_spec"
os.execute("rm -rf '" .. WORK .. "'")
package.loaded["utils.paths"] = {
    ensureBookWork = function(id) os.execute("mkdir -p '" .. WORK .. "/" .. id .. "'") end,
    bookWorkDir = function(id) return WORK .. "/" .. id end,
}

package.loaded["pluginloader"] = { enabled_plugins = { Config.selfPlugin() } }
package.loaded["source.registry"] = nil
local Registry = require("source.registry")

Assert.eq(Registry.meta("bookorbit").type, "book")
local source = Registry.resolve("bookorbit")
Assert.is_true(source:configured())

---@return any, any, any
local function run(method, ...)
    local a, b, c
    local n = select("#", ...)
    local args = { ... }
    args[n + 1] = function(x, y, z) a, b, c = x, y, z end
    source[method](source, unpack(args, 1, n + 1))
    Stubs.flush()
    return a, b, c
end

-- 地址照抄 /api/v1 也认；用户名去首尾空白。
local Client = require("source.bookorbit.client")
Assert.eq(Client.normalizeUrl(" https://b.example.com/api/v1/koreader/ "), "https://b.example.com")
Assert.is_false(Client.new({ server_url = "http://x", username = "u" }):configured())

-- 书架：全部书库（未选）→ 逐库分页，库名即分类，作者合并。
routes["GET /koreader/plugin/catalog/sections/libraries"] = json({ items = {
    { id = "1", title = "小说" }, { id = "2", title = "漫画" },
} })
routes["GET /koreader/plugin/catalog/books"] = function(opts)
    local lib, page = query(opts, "libraryId"), query(opts, "page")
    if lib == "1" and page == "1" then
        return json({ hasNext = true, items = { { id = 1, title = "长夜", authors = { "甲", "乙" }, seriesName = "夜" } } })
    end
    if lib == "1" then return json({ hasNext = false, items = { { id = 2, title = "白昼", authors = {} } } }) end
    return json({ hasNext = false, items = { { id = 3, title = "图册" } } })
end
local result = run("syncBooksAsync", nil)
Assert.eq(result.pulled, 3)
Assert.eq(reconciled.source_id, "bookorbit")
Assert.eq(reconciled.books[1].stable_id, "1")
Assert.eq(reconciled.books[1].authors, "甲 / 乙")
Assert.eq(reconciled.books[1].series, "夜")
Assert.eq(reconciled.books[1].category, "小说")
Assert.is_nil(reconciled.books[2].authors)
Assert.eq(reconciled.books[3].category, "漫画")
Assert.eq(calls[1].headers["x-auth-user"], "ann")
Assert.eq(calls[1].headers["x-auth-key"], "k")
Assert.eq(query(calls[2], "sort"), "title")
Assert.is_true(run("syncBooksAsync", { dirty_only = true }).skipped, "没有删书接口，只推脏行时跳过")

-- 选了书库只拉选中的；选中的库都没了不能拿空列表对账（会把书架判成远端已删）。
cfg.libraries = { ["2"] = true }
reconciled = nil
Assert.len(run("syncBooksAsync", nil) and reconciled.books, 1)
cfg.libraries = { ["9"] = true }
reconciled = nil
local none, err = run("syncBooksAsync", nil)
Assert.is_nil(none)
Assert.matches(err, "书库")
Assert.is_nil(reconciled)
cfg.libraries = nil

-- 鉴权失败给可读提示。
routes["GET /koreader/plugin/catalog/sections/libraries"] = { code = 401, body = "" }
none, err = run("syncBooksAsync", nil)
Assert.is_nil(none)
Assert.matches(err, "密码")

-- 开书：详情写回元数据，按偏好挑 epub（不挑有声书 / pdf），下载原件并登记路径。
routes["GET /koreader/plugin/catalog/books/1"] = function(opts)
    Assert.eq(query(opts, "deviceId"), "dev-1")
    return json({ id = 1, title = "长夜", authors = { "甲" }, description = "简介", seriesName = "夜",
        publisher = "某出版社", publishedDate = "2008-01-01T00:00:00.000Z", publishedYear = 2008,
        language = "zh", isbn10 = "7000000000", isbn13 = "9787000000000", rating = 5, files = {
        { id = 10, format = "m4b" }, { id = 11, format = "PDF" }, { id = 12, format = "EPUB", sizeBytes = 9 },
    } })
end
local path = run("openBookAsync", { source_id = "bookorbit", stable_id = "1" }, nil)
Assert.eq(path, WORK .. "/1/12.epub")
Assert.eq(touched[1].stable_id, "1")
Assert.eq(remembered["1"].intro, "简介")
Assert.eq(remembered["1"].authors, "甲")
Assert.eq(remembered["1"].meta.publisher, "某出版社")
Assert.eq(remembered["1"].meta.published, "2008-01-01T00:00:00.000Z", "原样交给 BookDB 规范化")
Assert.eq(remembered["1"].meta.language, "zh")
Assert.eq(remembered["1"].meta.isbn, "9787000000000", "优先 ISBN-13")
Assert.is_nil(remembered["1"].meta.rating, "用户自评分不当公共评分")
Assert.matches(calls[#calls].url, "/koreader/plugin/catalog/files/12/download$")
Assert.eq(calls[#calls].headers["x-auth-key"], "k", "下载带鉴权头")
Assert.is_nil(io.open(path .. ".part"), "临时文件改名后不留")

-- 已下载：直接开，不联网。
online = false
local before = #calls
Assert.eq(run("openBookAsync", { source_id = "bookorbit", stable_id = "1" }, nil), path)
Assert.eq(#calls, before)
local offline, oerr = run("openBookAsync", { source_id = "bookorbit", stable_id = "2" }, nil)
Assert.is_nil(offline)
Assert.matches(oerr, "网络不可用")
online = true

-- 没有能开的格式；下载非 2xx / 文件头不对都删文件报错。
routes["GET /koreader/plugin/catalog/books/2"] = json({ id = 2, title = "听书", files = { { id = 20, format = "m4b" } } })
local failed, ferr = run("openBookAsync", { source_id = "bookorbit", stable_id = "2" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "没有 KOReader 能打开")
routes["GET /koreader/plugin/catalog/books/3"] = json({ id = 3, title = "坏书", files = { { id = 30, format = "epub" } } })
download.code, download.body = 500, "<html>oops</html>"
failed, ferr = run("openBookAsync", { source_id = "bookorbit", stable_id = "3" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "500")
Assert.is_nil(io.open(WORK .. "/3/30.epub.part"))
download.code = 200
failed, ferr = run("openBookAsync", { source_id = "bookorbit", stable_id = "3" }, nil)
Assert.is_nil(failed)
Assert.matches(ferr, "校验失败")
Assert.is_nil(io.open(WORK .. "/3/30.epub"))
download.body = "PK\3\4epub"

-- 详情页补简介。
local detail = run("getDetailAsync", { source_id = "bookorbit", stable_id = "1" })
Assert.eq(detail.intro, "简介")
Assert.eq(detail.title, "长夜")
Assert.eq(detail.meta.isbn, "9787000000000")
Assert.eq(decode_mode, SIMPLE, "响应按 simple 模式解析（null → nil）")
routes["GET /koreader/plugin/catalog/books/4"] = json({ id = 4, title = "无日期", publishedYear = 1999, files = {} })
Assert.eq(run("getDetailAsync", { source_id = "bookorbit", stable_id = "4" }).meta.published, 1999, "没有日期退到年份")
-- 简介若带 HTML（BookOrbit 常见），入库前剥成纯文本，详情页不再露出 div/p。
routes["GET /koreader/plugin/catalog/books/5"] = json({
    id = 5, title = "带标签", description = "<div><p>第一段</p><p>第二段&amp;续</p></div>", files = {},
})
Assert.eq(run("getDetailAsync", { source_id = "bookorbit", stable_id = "5" }).intro, "第一段\n第二段&续")
Assert.eq(remembered["5"].intro, "第一段\n第二段&续")

-- 封面：缩略图接口带鉴权头。
local cover = source:coverRequest({ stable_id = "1" })
Assert.eq(cover.url, "http://bo/api/v1/koreader/plugin/catalog/books/1/thumbnail")
Assert.eq(cover.headers["x-auth-user"], "ann")

-- 拉进度：按本地文件摘要查；xpointer → locator；同一 xpointer 交回本地行；{} 算空；没下载算空。
local book1 = { source_id = "bookorbit", stable_id = "1" }
local DIGEST = ("a"):rep(32)
local remote = { percentage = 0.42, progress = "/body/DocFragment[3]/body/p[2]/text().0", timestamp = 1700000000 }
routes["GET /koreader/syncs/progress/" .. DIGEST] = function() return json(remote) end
local pos, perr0 = run("getProgressAsync", book1)
Assert.is_nil(perr0)
Assert.eq(pos.fraction, 0.42)
Assert.eq(pos.locator, remote.progress)
Assert.is_nil(pos.page)
Assert.eq(pos.updated_at, 1700000000)
progress["1"] = { locator = remote.progress, fraction = 0.4 }
Assert.eq(run("getProgressAsync", book1), progress["1"])
remote = { percentage = 0.5, progress = "12" }
pos = run("getProgressAsync", book1)
Assert.eq(pos.page, 12)
Assert.is_nil(pos.locator)
remote = {}
local empty, _e, meta = run("getProgressAsync", book1)
Assert.is_nil(empty)
Assert.is_true(meta.empty)
_e, _e, meta = run("getProgressAsync", { source_id = "bookorbit", stable_id = "9" })
Assert.is_true(meta.empty, "没下载没有摘要")

-- 推进度：xpointer / 页码串，时间用进度自己的；404 = 服务端不认识文件。
local sent
routes["PUT /koreader/syncs/progress"] = function(opts)
    sent = JSON.decode(opts.body)
    return json({ document = sent.document })
end
Assert.is_true(run("putProgressAsync", book1, { fraction = 0.3, locator = "/body/p[1]", updated_at = 1700000001 }))
Assert.eq(sent.document, DIGEST)
Assert.eq(sent.progress, "/body/p[1]")
Assert.eq(sent.percentage, 0.3)
Assert.eq(sent.timestamp, 1700000001)
Assert.eq(sent.device_id, "dev-1")
Assert.eq(sent.device, "Kindle")
run("putProgressAsync", book1, { fraction = 1.2, page = 7, total_pages = 9 })
Assert.eq(sent.progress, "7")
Assert.eq(sent.percentage, 1)
routes["PUT /koreader/syncs/progress"] = { code = 404, body = "" }
local okp, perr = run("putProgressAsync", book1, { fraction = 0.3 })
Assert.is_nil(okp)
Assert.matches(perr, "不认识")

-- 划线：只传带 drawer 的高亮，分块 50 条；keys 是空数组、keysComplete=false（不让服务端推断删除）。
local exchanged = {}
routes["POST /koreader/plugin/annotations/exchange"] = function(opts)
    exchanged[#exchanged + 1] = JSON.decode(opts.body)
    return json({ results = { {} }, unmatched = {} })
end
local anns = {
    { datetime = "2026-10-01 10:00:00", datetime_updated = "bad", drawer = "lighten", color = "yellow",
      text = "春眠不觉晓", note = "好诗", chapter = "一", pageno = 3, pos0 = "/body/p[1]/text().0", pos1 = "/body/p[1]/text().5" },
    { datetime = "2026-10-01 10:00:01", drawer = "underscore", text = "图", pos0 = { page = 2, x = 1, y = 2.345 },
      pos1 = { page = 2, x = 3, y = 4 } },
    { datetime = "2026-10-01 10:00:02", text = "书签", pos0 = "/body/p[2]" },
    { datetime = "昨天", drawer = "lighten", pos0 = "/body/p[3]" },
}
for idx = 1, 55 do
    anns[#anns + 1] = { datetime = "2026-10-02 10:00:00", drawer = "lighten", text = ("长"):rep(4000),
        pos0 = "/body/p[" .. (idx + 10) .. "]" }
end
Assert.is_true(run("pushNotesAsync", book1, anns))
Assert.len(exchanged, 2, "57 条分两块")
local first = exchanged[1]
Assert.eq(first.deviceId, "dev-1")
Assert.eq(first.pluginVersion, "moon-1.0")
Assert.matches(first.deviceTime, "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$")
local book = first.books[1]
Assert.eq(book.hash, DIGEST)
Assert.is_false(book.keysComplete)
Assert.eq(getmetatable(book.keys), ARRAY, "空 keys 必须编码成数组")
Assert.len(book.changes, 50)
Assert.len(exchanged[2].books[1].changes, 7)
local c1, c2 = book.changes[1], book.changes[2]
Assert.eq(c1.posFormat, "xpointer")
Assert.eq(c1.pos1, "/body/p[1]/text().5")
Assert.is_nil(c1.datetimeUpdated, "非法时间不传")
Assert.eq(c1.note, "好诗")
Assert.eq(c1.pageno, 3)
Assert.eq(c2.posFormat, "pdf")
Assert.eq(c2.pos0, '{"page":2,"x":1.00,"y":2.35}', "与官方插件同一种序列化，注解键才对得上")
Assert.eq(#book.changes[3].text, 9999, "超长按 UTF-8 字符边界截断")

-- 服务端不认识文件：报错，核心留脏重试；没有高亮不发请求。
routes["POST /koreader/plugin/annotations/exchange"] = json({ results = {}, unmatched = { DIGEST } })
local okn, nerr = run("pushNotesAsync", book1, { anns[1] })
Assert.is_nil(okn)
Assert.matches(nerr, "不认识")
before = #calls
Assert.is_true(run("pushNotesAsync", book1, { anns[3] }))
Assert.eq(#calls, before)

-- 设备 id：KOReader 没有（或格式不合）时自己生成一次并保存。
_G.G_reader_settings = { readSetting = function() return "has space" end }
routes["PUT /koreader/syncs/progress"] = function(opts)
    sent = JSON.decode(opts.body)
    return json({})
end
run("putProgressAsync", book1, { fraction = 0.1 })
Assert.matches(sent.device_id, "^%x+$")
Assert.eq(saved_cfg.device_id, sent.device_id)

-- 设置：密码只存 MD5，空串清掉；装了官方插件且有账号时多一行导入。
local Setting = require("source.bookorbit.setting")
local key_field = Setting.remote[3]
Assert.eq(key_field.key, "userkey")
Assert.is_true(key_field.secret)
Assert.eq(key_field.normalize(" pw "), require("ffi/sha2").md5("pw"))
Assert.eq(key_field.normalize("  "), "")
Assert.eq(Setting.remote[1].normalize("http://x/api/v1/"), "http://x")
Assert.len(Setting.rows(), 5)
_G.G_reader_settings = { readSetting = function(_self, key)
    return key == "bookorbit" and { server_url = "http://bo/api/v1", username = "u", userkey = "kk" } or nil
end }
Assert.len(Setting.rows(), 6)
_G.G_reader_settings = nil

os.execute("rm -rf '" .. WORK .. "'")
