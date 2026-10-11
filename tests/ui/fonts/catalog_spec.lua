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
        },
    }
    function FontList:getFontList() return self.fontlist end
    function FontList:_readList(dir, _mark)
        for _idx, file in ipairs({ "WenKai.ttf", "Plain.otf", "KaiCN.ttf", "skip.woff",
            "sub/Bare-Font.ttf", "sub/Plain.otf" }) do
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

GetText.current_lang = saved_lang
return true
