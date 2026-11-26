--[[-- features.marketplace.installed / catalog 版本比较：离线扫描、release_asset 推测、安装记录与兼容。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["json"] = function() return require("support.json_stub") end

local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local Installed = require("features.marketplace.installed")
local Catalog = require("features.marketplace.catalog")

local parent = Paths.root() .. "/marketplace-installed-test"
local plugin = parent .. "/stats.koplugin"
local function wipe(dir)
    local attr = lfs.attributes(dir, "mode")
    if attr == "directory" then
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    wipe(path)
                else
                    os.remove(path)
                end
            end
        end
        lfs.rmdir(dir)
    elseif attr then
        os.remove(dir)
    end
end
wipe(parent)
Catalog.clear()
Installed.clearRecords()
lfs.mkdir(Paths.root())
lfs.mkdir(parent)
lfs.mkdir(plugin)
local file = io.open(plugin .. "/_meta.lua", "w")
file:write('return { name = "stats", fullname = _("阅读统计"), version = "1.0.0" }\n')
file:close()

local items = Installed.scan(plugin)
Assert.eq(#items, 1)
Assert.eq(items[1].name, "stats.koplugin")
Assert.eq(items[1].title, "阅读统计")
Assert.eq(items[1].version, "1.0.0")
Assert.is_false(items[1].reserved)

Assert.is_true(Catalog.isNewer("1.1.0", "1.0.0"))
Assert.is_false(Catalog.isNewer("1.0.0", "1.0.0"))
Assert.is_false(Catalog.isNewer("1.0.0", "1.1.0"))
Assert.is_false(Catalog.isNewer(nil, "1.0.0"))
Assert.is_false(Catalog.isNewer("unknown", "1.0.0"))
Assert.is_false(Catalog.isNewer("1.0.0", nil))
-- 两段式版本、预发布后缀与日期型排除
Assert.is_true(Catalog.isNewer("1.2", "1.1"))
Assert.is_true(Catalog.isNewer("1.2.1", "1.2"))
Assert.is_false(Catalog.isNewer("1.2.0", "1.2"))
Assert.is_true(Catalog.isNewer("1.0.0", "1.0.0-beta.1"))
Assert.is_false(Catalog.isNewer("1.0.0-beta.1", "1.0.0"))
Assert.is_true(Catalog.isNewer("1.0.0-beta.10", "1.0.0-beta.2"))
Assert.is_true(Catalog.isNewer("1.0.0-rc.1", "1.0.0-beta.9"))
Assert.is_false(Catalog.isNewer("1.0.0+abc", "1.0.0"))
Assert.is_false(Catalog.isNewer("2026.05.01", "2026.04.01"))
Assert.is_false(Catalog.isNewer("2026.05", "2026.04"))

-- release_asset 优先用于推断插件目录名
Assert.eq(Installed.pluginDir({ repo = "koreader-my-repo", release_asset = "stats.koplugin-1.0.0.zip" }), "stats.koplugin")
Assert.is_false(Installed.isPluginDir("book.koplugin"))

-- 已安装过滤：只保留市场可核对的插件，排除月读和其他未知插件
local book = parent .. "/book.koplugin"
local wallpaper = parent .. "/wallpaper.koplugin"
local guess = parent .. "/ko-guess.koplugin"
lfs.mkdir(book)
lfs.mkdir(wallpaper)
lfs.mkdir(guess)
local function write_meta(dir, body)
    local fh = io.open(dir .. "/_meta.lua", "w")
    fh:write(body)
    fh:close()
end
write_meta(book, 'return { name = "book", fullname = _("月读"), version = "9.0.0" }\n')
write_meta(wallpaper, 'return { name = "wallpaper", fullname = _("壁纸"), version = "0.1.0" }\n')
write_meta(guess, 'return { name = "ko-guess", fullname = _("随便猜的"), version = "0.0.1" }\n')

local catalog = {
    {
        uid = "github:Acme/nice-plugin",
        type = "github", host = "https://github.com", owner = "Acme", repo = "nice-plugin",
        release_asset = "stats.koplugin-1.2.0.zip",
        title = "阅读统计", version = "1.2.0",
    },
}
local matched = Installed.supported(plugin, catalog)
Assert.eq(#matched, 1)
Assert.eq(matched[1].local_plugin.name, "stats.koplugin")
Assert.eq(matched[1].plugin.uid, "github:Acme/nice-plugin")

-- 离线安装记录仍可核对，且支持跨仓库名匹配
Installed.clearRecords()
Assert.is_true(Installed.remember({
    uid = "github:Acme/wallpaper-from-market",
    type = "github", host = "https://github.com",
    owner = "Acme", repo = "wallpaper-from-market",
    title = "壁纸扩展",
}, "wallpaper.koplugin"))
matched = Installed.supported(plugin, {})
Assert.eq(#matched, 1)
Assert.eq(matched[1].local_plugin.name, "wallpaper.koplugin")
Assert.eq(matched[1].plugin.uid, "github:Acme/wallpaper-from-market")

-- 不传 catalog 数组时直查 SQLite 相交行，不解码全库
Catalog.saveCache({ updated_at = os.time(), categories = {}, plugins = catalog })
local db_matched = Installed.supported(plugin, nil)
Assert.eq(#db_matched, 2, "SQLite 索引匹配应命中 stats.koplugin（目录）与 wallpaper.koplugin（记录）")
Catalog.clear()

-- findLocal 可经安装记录定位仓库名与目录名不一致的已装插件
local loc = Installed.findLocal({ uid = "github:Acme/wallpaper-from-market", repo = "wallpaper-from-market" }, plugin)
Assert.not_nil(loc)
Assert.eq(loc.name, "wallpaper.koplugin")

-- 本地 _meta.lua 缺失 version 时，用安装记录里保存的版本兜底判定更新
local nover = parent .. "/nover.koplugin"
lfs.mkdir(nover)
write_meta(nover, 'return { name = "nover", fullname = _("无版本插件") }\n')
Assert.is_true(Installed.remember({
    uid = "github:Acme/nover-plugin",
    type = "github", host = "https://github.com",
    owner = "Acme", repo = "nover-plugin",
    title = "无版本插件", release_tag = "v1.0",
}, "nover.koplugin"))
local nover_loc = Installed.findLocal({ uid = "github:Acme/nover-plugin", version = "1.1" }, plugin)
Assert.not_nil(nover_loc)
Assert.eq(nover_loc.version, "1.0")
Assert.is_true(Catalog.isNewer("1.1", nover_loc.version))
local nover_matched = Installed.supported(plugin, {
    { uid = "github:Acme/nover-plugin", version = "1.1" },
})
local found_nover
for _idx, row in ipairs(nover_matched) do
    if row.local_plugin.name == "nover.koplugin" then found_nover = row end
end
Assert.not_nil(found_nover)
Assert.eq(found_nover.local_plugin.version, "1.0")

-- 拒绝记录 book.koplugin
local ok_res, err_res = Installed.remember({ uid = "x" }, "book.koplugin")
Assert.is_nil(ok_res)
Assert.eq(err_res, "reserved")

-- 停用写入 KOReader 的 plugins_disabled；删除清目录和记录，不碰月读核心。
local gone = parent .. "/gone.koplugin"
lfs.mkdir(gone)
local marker = io.open(gone .. "/main.lua", "w")
marker:write("return {}\n")
marker:close()
Assert.is_true(Installed.remember({
    uid = "gone", type = "github", host = "github.com", owner = "a", repo = "gone",
}, "gone.koplugin"))
local disabled = {}
local previous_settings = rawget(_G, "G_reader_settings")
_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "plugins_disabled" then return disabled end
    end,
    saveSetting = function(_, key, value)
        if key == "plugins_disabled" then disabled = value end
    end,
    flush = function() end,
}
Assert.is_true(Installed.setDisabled("gone.koplugin", true))
Assert.is_true(Installed.isDisabled("gone.koplugin"))
Assert.eq(disabled.gone, true)
Assert.is_true(Installed.setDisabled("gone.koplugin", false))
Assert.is_true(not Installed.isDisabled("gone.koplugin"))
Assert.is_nil(disabled.gone)
Assert.is_nil(Installed.setDisabled("book.koplugin", true))
Assert.is_true(Installed.remove(plugin, "gone.koplugin"))
Assert.is_nil(lfs.attributes(gone, "mode"))
Assert.is_nil(Installed.remove(plugin, "book.koplugin"))
Assert.is_nil(Installed.remove(plugin, "../gone.koplugin"))
_G.G_reader_settings = previous_settings

wipe(parent)
Catalog.clear()
Installed.clearRecords()
return true
