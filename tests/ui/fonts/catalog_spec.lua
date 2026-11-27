--[[--
ui.fonts.catalog：
- listLocalAsync：只扫描本地（用户/本地/系统），零联网，按 mtime 缓存并支持 invalidateLocalScan；
- listOnlineAsync：moon-store.ankio.net API 分页 + http.Cache（24 小时 TTL），失败回落旧缓存；
- downloadToUserAsync：直接把 TTF 下载到 $DATA/fonts/<filename>，子进程校验 SFNT 魔数并按需补空格。

@module tests.ui.fonts.catalog_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

package.preload["datastorage"] = function()
    return { getDataDir = function() return Config.dir() end }
end
package.preload["ui/font"] = function() return { fontmap = {}, faces = {} } end
local root = Config.dir() .. "/fonts"
local GetText = require("gettext")
local saved_lang = GetText.current_lang
GetText.current_lang = "zh_TW"
package.preload["fontlist"] = function()
    local FontList = {
        fontlist = { "/sys/System.ttf" },
        fontinfo = {
            ["/sys/System.ttf"] = { { name = "System Sans" } },
            [root .. "/WenKai.ttf"] = { { name = "LXGW WenKai" } },
            [root .. "/Plain.otf"] = { { name = "Plain Sans" } },
            [root .. "/KaiCN.ttf"] = { { name = "Kai CN", names = { ["zh-cn"] = { [1] = "简体楷" } } } },
            [root .. "/sub/Bare-Bold.ttf"] = { { name = "Bare Bold", bold = true } },
            [root .. "/sub/Bare-Italic.ttf"] = { { name = "Bare Italic", italic = true } },
        },
    }
    function FontList:getFontList() return self.fontlist end
    function FontList:_readList(dir, _mark)
        for _idx, file in ipairs({ "WenKai.ttf", "Plain.otf", "KaiCN.ttf", "UserWeb.woff",
            "sub/Bare-Font.ttf", "sub/Plain.otf", "sub/sub.woff", "sub/Bare-Bold.ttf", "sub/Bare-Italic.ttf" }) do
            table.insert(self.fontlist, dir .. "/" .. file)
        end
    end
    function FontList:getLocalizedFontName(path, _index)
        return path == root .. "/WenKai.ttf" and "霞鹜文楷" or nil
    end
    return FontList
end
package.preload["json"] = function()
    local Json = require("support.json_stub")
    return { decode = Json.decode, encode = Json.encode }
end
package.preload["util"] = function() return { findFiles = function() end } end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local f = io.open(path, "rb")
            if f then f:close(); return key == "mode" and "file" or { mode = "file" } end
            return nil
        end,
        mkdir = function() return true end,
    }
end
package.preload["utils.paths"] = function()
    return {
        fontsDir = function() return Config.dir() .. "/font_legacy_absent" end,
        ensureDir = function(dir) os.execute("mkdir -p '" .. dir .. "'") end,
    }
end
local ui_settings = {}
package.preload["utils.settings"] = function()
    return { get = function() return ui_settings end, save = function() end }
end

local body = '{"data":[{"uid":"f1","name":"霞鹜文楷","filename":"WenKai.ttf","size_bytes":2048,"size_label":"2 KB","category":"kai","category_name":"楷体","preview_url":"/api/v1/store/fonts/f1/preview","name_preview_url":"/api/v1/store/fonts/f1/preview?mode=name","download_url":"/api/v1/store/fonts/f1/download"}],"count":1}'
local gets = {}
local custom_get = nil
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            gets[#gets + 1] = { url = url, opts = opts }
            if custom_get then return custom_get(url, opts, cb) end
            cb(body)
            return { cancel = function() end }
        end,
    }
end
local cache_store = {}
package.preload["http.cache"] = function()
    return {
        key = function(method, url) return string.upper(method or "GET") .. " " .. url end,
        forget = function(key)
            if type(key) == "string" and key ~= "" then cache_store[key] = nil end
        end,
        fetch = function(key, ttl, load, cb, opts)
            opts = opts or {}
            if key then
                local row = cache_store[key]
                if row and row.expires > os.time() then
                    cb(row.value)
                    return { cancel = function() end }
                end
                if opts.swr and row then
                    cb(row.value)
                    return load(function(value, err)
                        if value ~= nil and err == nil then
                            cache_store[key] = { value = value, expires = os.time() + ttl }
                        end
                    end) or { cancel = function() end }
                end
            end
            return load(function(value, err)
                if value ~= nil and err == nil then
                    if key then cache_store[key] = { value = value, expires = os.time() + ttl } end
                    cb(value, err)
                    return
                end
                if opts.stale_on_error and key and cache_store[key] then
                    cb(cache_store[key].value)
                    return
                end
                cb(value, err)
            end) or { cancel = function() end }
        end,
    }
end
local scans = 0
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            scans = scans + 1
            opts.on_done(worker())
            return { cancel = function() end }
        end,
    }
end

package.loaded["ui.fonts"] = nil
package.loaded["ui.fonts.catalog"] = nil
local Catalog = require("ui.fonts.catalog")
local Fonts = require("ui.fonts")

-- 1. listLocalAsync：绝不发网络，按分组返回用户/本地/系统
local local_items, local_err
Catalog.listLocalAsync(function(result, e) local_items, local_err = result, e end)
Assert.is_nil(local_err)
Assert.len(gets, 0, "本地字体列表不得触发任何网络请求")
Assert.eq(scans, 1)
local out, woff_item = {}, nil
for _idx, it in ipairs(local_items) do
    out[#out + 1] = it.kind .. ":" .. it.id .. "=" .. it.name
    if it.id == "UserWeb.woff" then woff_item = it end
end
-- 用户/本地目录放进来的字体一律如实显示，哪怕内部被标了 bold/italic（回归：kindle 圆体放进去看不到）；
-- 只有系统字体目录的 bold/italic 同族冗余变体才跳过。
Assert.eq(table.concat(out, ","), "user:Plain.otf=Plain Sans,user:UserWeb.woff=UserWeb,user:KaiCN.ttf=简体楷,user:WenKai.ttf=霞鹜文楷,"
    .. "local:Bare-Bold.ttf=Bare Bold,local:Bare-Italic.ttf=Bare Italic,local:Bare-Font.ttf=Bare-Font,system:System.ttf=System Sans")
Assert.not_nil(woff_item, "用户目录的 woff 字体应被列出")
Assert.is_true(woff_item.woff, "用户目录的 woff 字体应标明 woff = true")

-- 会话内复用缓存，invalidateLocalScan 后重扫
Catalog.listLocalAsync(function(result) local_items = result end)
Assert.eq(scans, 1)
Catalog.invalidateLocalScan()
Catalog.listLocalAsync(function(result) local_items = result end)
Assert.eq(scans, 2)

-- 2. listOnlineAsync：moon-store 分页、缓存与过期回落
local online_items, online_err
Catalog.listOnlineAsync(function(result, e) online_items, online_err = result, e end)
Assert.is_nil(online_err)
Assert.len(gets, 1)
Assert.eq(gets[1].url, Catalog.LIST_URL .. "?page=1&pageSize=100")
Assert.eq(online_items[1].id, "f1")
Assert.eq(online_items[1].filename, "WenKai.ttf")
Assert.eq(online_items[1].category, "kai")
Assert.eq(online_items[1].category_name, "楷体")
Assert.eq(online_items[1].size_label, "2 KB")
Assert.eq(online_items[1].url, "https://moon-store.ankio.net/api/v1/store/fonts/f1/download")
Assert.eq(online_items[1].preview, "https://moon-store.ankio.net/api/v1/store/fonts/f1/preview?mode=name")
Assert.eq(Catalog.targetFilename(online_items[1]), "WenKai.ttf")
Assert.eq(Catalog.targetFilename({ id = "f_abc", filename = "../evil.ttf" }), "f_abc.ttf", "非法文件名回落到安全 uid.ttf")

-- 命中缓存不联网
local list_key = "GET " .. Catalog.LIST_URL
Catalog.listOnlineAsync(function(result) online_items = result end)
Assert.len(gets, 1)

-- 强制刷新重拉
Catalog.listOnlineAsync(function(result) online_items = result end, { force = true })
Assert.len(gets, 2)

-- 分页拉取与排序
do
    local saved_size = Catalog.PAGE_SIZE
    Catalog.PAGE_SIZE = 1
    cache_store[list_key] = nil
    local before = #gets
    custom_get = function(url, _opts, cb)
        if url:find("page=1", 1, true) then
            cb('{"data":[{"uid":"b","name":"Beta","filename":"Beta.ttf","category":"hei","download_url":"/api/v1/store/fonts/b/download"}],"count":2}')
        else
            cb('{"data":[{"uid":"a","name":"Alpha","filename":"Alpha.ttf","category":"song","download_url":"/api/v1/store/fonts/a/download"}],"count":2}')
        end
        return { cancel = function() end }
    end
    Catalog.listOnlineAsync(function(result) online_items = result end)
    Assert.eq(#gets - before, 2)
    Assert.eq(online_items[1].id, "a")
    Assert.eq(online_items[2].id, "b")
    custom_get = nil
    Catalog.PAGE_SIZE = saved_size
end

-- 过期且拉取失败：回落旧缓存
cache_store[list_key].expires = os.time() - 1
custom_get = function(_url, _opts, cb) cb(nil, "network down"); return { cancel = function() end } end
Catalog.listOnlineAsync(function(result, e) online_items, online_err = result, e end)
Assert.eq(online_items[1].id, "a")
Assert.is_nil(online_err)
custom_get = nil

-- 解析失败不写缓存
cache_store[list_key] = nil
body = "<html>oops</html>"
Catalog.listOnlineAsync(function(result, e) online_items, online_err = result, e end)
Assert.is_nil(online_items)
Assert.eq(online_err, "字体列表解析失败")
Assert.is_nil(cache_store[list_key])

-- stale-while-revalidate：过期旧缓存先显示，后台刷新缓存供下次（慢接口不干等）
do
    cache_store[list_key] = {
        value = { { id = "old", name = "旧字体", kind = "online", url = "https://x/old" } },
        expires = os.time() - 1,
    }
    local before = #gets
    custom_get = function(_url, _opts, cb)
        cb('{"data":[{"uid":"new","name":"新字体","filename":"New.ttf","category":"song","download_url":"/api/v1/store/fonts/new/download"}],"count":1}')
        return { cancel = function() end }
    end
    local served, served_err
    Catalog.listOnlineAsync(function(result, e) served, served_err = result, e end)
    Assert.eq(served[1].id, "old", "SWR 先回落过期旧缓存")
    Assert.is_nil(served_err)
    Assert.is_true(#gets > before, "SWR 后台触发刷新请求")
    Assert.eq(cache_store[list_key].value[1].id, "new", "后台刷新写回新缓存")
    custom_get = nil
    local again
    Catalog.listOnlineAsync(function(result) again = result end)
    Assert.eq(again[1].id, "new", "下次打开命中刷新后的新缓存")
end

-- 3. downloadToUserAsync：直接下载到 $DATA/fonts/<filename>，拦截假 200 HTML，校验 SFNT + ensureSpace 后原子落盘
do
    local user_dir = Fonts.settingsFontsDir()
    os.execute("mkdir -p '" .. user_dir .. "'")
    local dest = user_dir .. "/MySong.ttf"
    os.remove(dest)
    os.remove(dest .. ".dl")

    -- HTML 劫持页拒绝落盘
    require("http.request").download = function(_opts, dl_dest, cb)
        local f = assert(io.open(dl_dest, "wb"))
        f:write("<html>blocked</html>")
        f:close()
        cb(true)
        return { cancel = function() end }
    end
    local ok, detail
    Catalog.downloadToUserAsync({
        id = "f_song", name = "我的宋体", filename = "MySong.ttf", kind = "online",
        url = "https://moon-store.ankio.net/api/v1/store/fonts/f_song/download", size = 12,
    }, nil, function(r, d) ok, detail = r, d end)
    Assert.is_nil(ok)
    Assert.eq(detail, "字体安装失败")
    Assert.is_nil(io.open(dest, "rb"))
    Assert.is_nil(io.open(dest .. ".dl", "rb"))

    -- 正常 TTF 下载 → 校验魔数 → ensureSpace → 落到用户字体目录
    local repaired_path
    require("ui.fonts.sfnt").ensureSpace = function(p) repaired_path = p; return false end
    require("http.request").download = function(_opts, dl_dest, cb)
        local f = assert(io.open(dl_dest, "wb"))
        f:write("\0\1\0\0ttf-content")
        f:close()
        cb(true)
        return { cancel = function() end }
    end
    local item = {
        id = "f_song", name = "我的宋体", filename = "MySong.ttf", kind = "online",
        url = "https://moon-store.ankio.net/api/v1/store/fonts/f_song/download", size = 15,
    }
    Assert.is_false(Catalog.isDownloadedToUser(item))
    Catalog.downloadToUserAsync(item, nil, function(r, d) ok, detail = r, d end)
    Assert.is_true(ok)
    Assert.eq(detail, "MySong.ttf")
    Assert.eq(repaired_path, dest .. ".dl")
    Assert.is_true(Catalog.isDownloadedToUser(item))
    Assert.is_nil(io.open(dest .. ".dl", "rb"))

    os.remove(dest)
    os.execute("rmdir '" .. user_dir .. "' 2>/dev/null || true")
end

-- 内存不够时拒绝开下，不碰网络
do
    local called = false
    local saved_mem = package.loaded["utils.mem"]
    package.loaded["utils.mem"] = {
        canAfford = function()
            return false, "memory insufficient need=35MB avail=8MB", {}
        end,
    }
    require("http.request").download = function()
        called = true
        return { cancel = function() end }
    end
    local ok, detail
    Catalog.downloadToUserAsync({
        id = "big", name = "京华老宋体", filename = "Big.ttf", kind = "online",
        url = "https://moon-store.example/font", size = 35 * 1024 * 1024,
    }, nil, function(r, d) ok, detail = r, d end)
    Assert.is_nil(ok)
    Assert.is_true(type(detail) == "string" and detail:find("memory insufficient", 1, true) ~= nil)
    Assert.is_false(called, "内存不够不得发起下载")
    package.loaded["utils.mem"] = saved_mem
end

GetText.current_lang = saved_lang
return true
