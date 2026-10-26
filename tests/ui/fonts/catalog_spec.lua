--[[--
ui.fonts.catalog 字体列表：微信列表走 Request.get 的 cache_ttl，解析失败清缓存并带回错误。

@module tests.ui.fonts.catalog_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

package.preload["ffi/archiver"] = function() return {} end
package.preload["datastorage"] = function()
    return { getDataDir = function() return Config.dir() end }
end
package.preload["ui/font"] = function() return { fontmap = {}, faces = {} } end
-- fonts 根目录：本地化名一项、族名一项、只登记 zh-cn 名一项、woff 一项；
-- 子目录：无 fontinfo 一项、与根目录同 basename 一项；系统字库单独成组
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
            -- 粗体/斜体变体：CRE 只能按族名切字体，选了等于没选，不列
            [root .. "/sub/Bare-Bold.ttf"] = { { name = "Bare", bold = true } },
            [root .. "/sub/Bare-Italic.ttf"] = { { name = "Bare", italic = true } },
        },
    }
    function FontList:getFontList() return self.fontlist end
    function FontList:_readList(dir, _mark)
        for _idx, file in ipairs({ "WenKai.ttf", "Plain.otf", "KaiCN.ttf", "skip.woff",
            "sub/Bare-Font.ttf", "sub/Plain.otf", "sub/Bare-Bold.ttf", "sub/Bare-Italic.ttf" }) do
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
    return { attributes = function() return nil end }
end
package.preload["utils.paths"] = function()
    return {
        fontsDir = function() return Config.dir() .. "/font_list_spec_absent" end,
        ensureFonts = function() end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return {} end }
end

local body = '{"items":[{"id":"f1","name":"F1","url":"https://x/f1.zip"}]}'
local gets, cleared = {}, {}
package.preload["http.request"] = function()
    return {
        get = function(url, opts, cb)
            gets[#gets + 1] = { url = url, opts = opts }
            cb(body)
            return { cancel = function() end }
        end,
    }
end
package.preload["http.cache"] = function()
    return { clear = function(sub) cleared[#cleared + 1] = sub end }
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

local items, err
local function list()
    Catalog.listAsync(function(result, e) items, err = result, e end)
end
local function installed()
    local out = {}
    for _idx, it in ipairs(items) do
        if it.kind ~= "weread" then out[#out + 1] = it.kind .. ":" .. it.id .. "=" .. it.name end
    end
    return table.concat(out, ",")
end

list()
Assert.len(gets, 1)
Assert.is_true(gets[1].opts.cache_ttl > 0, "列表走 http.Cache TTL")
Assert.eq(items[1].id, "f1")
Assert.eq(items[1].kind, "weread")
Assert.is_nil(err)
Assert.len(cleared, 0)
Assert.eq(scans, 1)

-- 分组：fonts 根目录 = 用户，子目录 = 本地，FontList 其余 = 系统；
-- 显示名：本地化名 → 中文界面任一中文名 → 族名 → 文件名；同 basename 只留先到的；woff 不列
Assert.eq(installed(), "user:Plain.otf=Plain Sans,user:KaiCN.ttf=简体楷,user:WenKai.ttf=霞鹜文楷,"
    .. "local:Bare-Font.ttf=Bare-Font,system:System.ttf=System Sans")

-- 再次打开：本地扫描会话内复用，不再起子进程；微信列表仍走 http.Cache
list()
Assert.eq(scans, 1, "本地字体一个会话只扫一次")
Assert.len(gets, 2)
Assert.eq(items[1].id, "f1")

-- 坏数据：清掉缓存，别让它在 TTL 内一直命中；列表仍回调（只剩本地）并带错误
body = "<html>oops</html>"
list()
Assert.len(cleared, 1)
Assert.eq(cleared[1], gets[3].url)
Assert.len(items, 5)
Assert.eq(items[1].kind, "user")
Assert.eq(err, "字体列表解析失败")

-- 英文界面不退回中文名（重载模块以重扫）
GetText.current_lang = "en"
package.loaded["ui.fonts.catalog"] = nil
Catalog = require("ui.fonts.catalog")
list()
Assert.eq(installed(), "user:KaiCN.ttf=Kai CN,user:Plain.otf=Plain Sans,user:WenKai.ttf=霞鹜文楷,"
    .. "local:Bare-Font.ttf=Bare-Font,system:System.ttf=System Sans")

-- 下载到的不是 zip（强制门户 / CDN 错误页以 200 返回）：解压前按魔数拒绝，删掉残包，回调失败
do
    local dir = Config.dir() .. "/font_list_spec_absent"
    os.execute("mkdir -p '" .. dir .. "'")
    require("http.request").download = function(_opts, dest, cb)
        local f = assert(io.open(dest, "wb"))
        f:write("<html>blocked</html>")
        f:close()
        cb(true)
        return { cancel = function() end }
    end
    local ok, e
    Catalog.ensureInstalledAsync({ name = "f1", kind = "weread", id = "f1", url = "https://x/f1.zip" }, nil,
        function(r, er) ok, e = r, er end)
    Assert.is_nil(ok)
    Assert.eq(e, "字体解压失败")
    Assert.is_nil(io.open(dir .. "/f1.zip", "rb"), "残包已删")
    os.execute("rm -rf '" .. dir .. "'")
end

-- 已下载字体必须先在 fork Job 中准备，主线程和取消后的回调都不能修复/保存。
do
    local Fonts = require("ui.fonts")
    local dir = Config.dir() .. "/font_prepare_spec"
    os.execute("mkdir -p '" .. dir .. "'")
    local function write(path, data)
        local f = assert(io.open(path, "wb"))
        assert(f:write(data))
        f:close()
    end
    Fonts.wereadPath = function(id) return dir .. "/" .. id .. ".ttf" end
    Fonts.isFile = function(path)
        local f = io.open(path, "rb")
        if not f then return false end
        f:close()
        return true
    end
    Fonts.downloadedPath = function(id)
        local path = Fonts.wereadPath(id)
        if Fonts.isFile(path) then return path end
        path = path:gsub("%.ttf$", ".woff")
        return Fonts.isFile(path) and path or nil
    end
    local jobs, in_worker, repairs, repair_error = {}, false, {}, nil
    require("workers.job").run = function(worker, opts)
        local job = { worker = worker, opts = opts }
        function job:cancel() self.cancelled = true end
        jobs[#jobs + 1] = job
        return job
    end
    local function run(job)
        in_worker = true
        local err = job.worker()
        in_worker = false
        job.opts.on_done(err)
    end
    require("ui.fonts.sfnt").ensureSpace = function(path)
        Assert.is_true(in_worker, "字体修复只在 Job 内运行")
        repairs[#repairs + 1] = path
        if repair_error then return nil, repair_error end
        return true
    end
    package.loaded["ui.fonts.woff"] = { toSfnt = function(_src, dest)
        Assert.is_true(in_worker, "旧 WOFF 转换也不在 UI 线程")
        write(dest, "test-sfnt")
        return true
    end }
    local called, result, failure = 0, nil, nil
    local function callback(ok, err)
        called, result, failure = called + 1, ok, err
    end
    write(Fonts.wereadPath("aik"), "test-sfnt")
    local handle = Catalog.ensureInstalledAsync({ name = "aik", kind = "weread", id = "aik" }, nil, callback)
    Assert.eq(called, 0, "返回前不回调成功")
    Assert.len(repairs, 0, "返回前不读写字体")
    Assert.eq(jobs[1].opts.name, "font.prepare")
    Assert.eq(jobs[1].opts.kind, "medium")
    run(jobs[1])
    Assert.is_true(result)
    Assert.eq(called, 1)
    Assert.eq(repairs[1], Fonts.wereadPath("aik"))

    handle = Catalog.ensureInstalledAsync({ name = "aik", kind = "weread", id = "aik" }, nil, callback)
    handle.cancel()
    Assert.is_true(jobs[2].cancelled)
    jobs[2].opts.on_done(nil)
    Assert.eq(called, 1, "取消后迟到的结果不能继续应用字体")

    repair_error = "disk full"
    Catalog.ensureInstalledAsync({ name = "aik", kind = "weread", id = "aik" }, nil, callback)
    run(jobs[3])
    Assert.is_nil(result)
    Assert.eq(failure, "应用字体失败")
    Assert.is_true(Fonts.isFile(Fonts.wereadPath("aik")), "修复失败不删除已有字体")
    repair_error = nil

    Catalog.ensureInstalledAsync({ name = "aik", kind = "weread", id = "aik" }, nil, callback)
    jobs[4].opts.on_failed("worker failed")
    Assert.is_nil(result)
    Assert.eq(failure, "应用字体失败", "子进程失败不能报成功")

    write(dir .. "/legacy.woff", "test-woff")
    Catalog.ensureInstalledAsync({ name = "legacy", kind = "weread", id = "legacy" }, nil, callback)
    Assert.is_false(Fonts.isFile(Fonts.wereadPath("legacy")))
    run(jobs[5])
    Assert.is_true(result)
    Assert.eq(repairs[#repairs], Fonts.wereadPath("legacy"))
    Assert.is_false(Fonts.isFile(dir .. "/legacy.woff"))

    -- 新下载在原解包 Job 内修复，不再启动第二个 Job。
    package.loaded["ffi/archiver"].Reader = { new = function()
        return {
            open = function() return true end,
            iterate = function()
                local first = true
                return function()
                    if first then first = false; return { path = "font.woff", mode = "file", size = 9 } end
                end
            end,
            extractToPath = function(_self, _path, dest) write(dest, "test-woff") end,
            close = function() end,
        }
    end }
    require("http.request").download = function(_opts, dest, cb)
        write(dest, "PK\3\4")
        cb(true)
        return { cancel = function() end }
    end
    Catalog.ensureInstalledAsync({ name = "new", kind = "weread", id = "new", url = "https://x/new.zip" }, nil, callback)
    Assert.eq(jobs[6].opts.name, "font.extract")
    run(jobs[6])
    Assert.is_true(result)
    Assert.eq(repairs[#repairs], Fonts.wereadPath("new"))
    Assert.len(jobs, 6)

    repair_error = "repair failed"
    Catalog.ensureInstalledAsync({ name = "bad", kind = "weread", id = "bad", url = "https://x/bad.zip" }, nil, callback)
    run(jobs[7])
    Assert.is_nil(result)
    Assert.eq(failure, "字体解压失败")
    Assert.is_false(Fonts.isFile(Fonts.wereadPath("bad")), "新安装失败不能留下伪装成功的字体")
    for _, id in ipairs({ "aik", "legacy", "new" }) do os.remove(Fonts.wereadPath(id)) end
    os.remove(dir .. "/bad.ttf.space.part")
    os.execute("rmdir '" .. dir .. "'")
end

GetText.current_lang = saved_lang
return true
