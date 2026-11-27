--[[--
拆出的书源：书库（含墓碑）、非空源配置、活跃源才算用过。
enabled_sources 不算。空配置文件不算。插件已在或源已加载不算。
市场里有 zip 的可以装；没有的不记跳过。关掉之后不再问。离线不弹窗。
--]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["json"] = function() return require("support.json_stub") end

local DB = require("utils.db")
local Paths = require("utils.paths")
local Settings = require("utils.settings")
local lfs = require("libs/libkoreader-lfs")
require("book.books_db")
local Catalog = require("features.marketplace.catalog")
local Migrate = require("features.marketplace.migrate")
local Registry = require("source.registry")

local IDS = { "weread", "wechat", "fanqie", "qidian", "legado", "copymanga" }

local function wipe(id)
    DB.exec("DELETE FROM books WHERE source_id=?;", id)
    os.remove(Paths.sourcePath(id))
end

local function writeSettings(id, body)
    local file = assert(io.open(Paths.sourcePath(id), "w"))
    file:write(body)
    file:close()
end

local function find(list, plugin)
    for _idx, item in ipairs(list) do
        if item.plugin == plugin then return item end
    end
end

for _idx, id in ipairs(IDS) do wipe(id) end
Catalog.clear()
local saved = Settings.get("features.marketplace")
saved.source_install_skip = nil
Settings.save("features.marketplace")
local source_cfg = Settings.get("source")
local previous_active = source_cfg.active_source
local previous_enabled = source_cfg.enabled_sources

local base = Config.dir() .. "/migrate_plugins"
os.execute("rm -rf '" .. base .. "'")
assert(lfs.mkdir(base))
assert(lfs.mkdir(base .. "/book.koplugin"))
local root = base .. "/book.koplugin"

DB.exec([[INSERT INTO books (source_id, stable_id, title, deleted, sync_status)
    VALUES ('weread', 'migrate-weread', '微信', 1, 1);]])
DB.exec([[INSERT INTO books (source_id, stable_id, title, deleted, sync_status)
    VALUES ('wechat', 'migrate-wechat', '旧微信', 0, 1);]])
writeSettings("fanqie", "return {\n    token = \"t\",\n}\n")
writeSettings("copymanga", "return {\n}\n")
source_cfg.active_source = "qidian"
source_cfg.enabled_sources = { legado = true }

local pending = Migrate.pending(root)
local weread = find(pending, "moonsource-weread.koplugin")
Assert.not_nil(weread)
Assert.eq(weread.ids[1], "weread")
Assert.eq(weread.ids[2], "wechat")
Assert.eq(#weread.ids, 2, "wechat 跟 weread 是同一个插件")
Assert.not_nil(find(pending, "moonsource-fanqie.koplugin"))
Assert.not_nil(find(pending, "moonsource-qidian.koplugin"))
Assert.is_nil(find(pending, "moonsource-legado.koplugin"), "只出现在 enabled_sources 里不算用过")
Assert.is_nil(find(pending, "moonsource-copymanga.koplugin"), "空配置文件不算用过")

assert(lfs.mkdir(base .. "/moonsource-qidian.koplugin"))
pending = Migrate.pending(root)
Assert.is_nil(find(pending, "moonsource-qidian.koplugin"), "插件目录已经在就不再问")
assert(lfs.rmdir(base .. "/moonsource-qidian.koplugin"))

Catalog.saveCache({ plugins = {
    {
        uid = "gitea:git.garfieldho.me:moon-source/moonsource-weread",
        type = "gitea", host = "https://git.garfieldho.me", owner = "moon-source", repo = "moonsource-weread",
        title = "月读书源：微信读书",
        release_asset = "moonsource-weread.koplugin-0.0.1.zip",
        release_url = "https://git.garfieldho.me/moon-source/moonsource-weread/releases/download/v0.0.1/moonsource-weread.koplugin-0.0.1.zip",
    },
} })
pending = Migrate.pending(root)
local ready, waiting = Migrate.split(pending)
Assert.eq(#ready, 1)
Assert.eq(ready[1].plugin, "moonsource-weread.koplugin")
Assert.not_nil(ready[1].asset)
local waiting_plugins = {}
for _idx, item in ipairs(waiting) do waiting_plugins[item.plugin] = true end
Assert.is_true(waiting_plugins["moonsource-fanqie.koplugin"])
Assert.is_true(waiting_plugins["moonsource-qidian.koplugin"])
Assert.is_nil(waiting_plugins["moonsource-weread.koplugin"])

Migrate.remember(ready)
pending = Migrate.pending(root)
Assert.is_nil(find(pending, "moonsource-weread.koplugin"), "关掉或装过的不再问")
Assert.not_nil(find(pending, "moonsource-fanqie.koplugin"), "市场里还没有的不记跳过")

Registry.registerHidden("fanqie", function()
    return { meta = function() return { id = "fanqie", name = "番茄", type = "chapter" } end }
end)
pending = Migrate.pending(root)
Assert.is_nil(find(pending, "moonsource-fanqie.koplugin"), "源模块已经加载就不再问")

saved.source_install_skip = nil
Settings.save("features.marketplace")
for _idx, id in ipairs(IDS) do wipe(id) end
DB.exec([[INSERT INTO books (source_id, stable_id, title, deleted, sync_status)
    VALUES ('weread', 'migrate-offer', '微信', 0, 1);]])
source_cfg.active_source = "local"

local dialogs = {}
local connected = false
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }
package.loaded["ui.themes.widgets.confirm"] = {
    new = function(_self, opts)
        dialogs[#dialogs + 1] = opts
        return { show = function() end }
    end,
}

Migrate.offer({ plugin = { path = root } })
Assert.eq(#dialogs, 0, "离线不弹")
Assert.is_nil(Settings.get("features.marketplace").source_install_skip)

connected = true
Migrate.offer({ plugin = { path = root } })
Assert.eq(#dialogs, 1)
Assert.eq(dialogs[1].title, "安装书源插件")
dialogs[1].cancel_callback()
Assert.is_true(Settings.get("features.marketplace").source_install_skip.weread)

source_cfg.active_source = previous_active
source_cfg.enabled_sources = previous_enabled
Settings.save("source")
for _idx, id in ipairs(IDS) do wipe(id) end
saved.source_install_skip = nil
Settings.save("features.marketplace")
Catalog.clear()
os.execute("rm -rf '" .. base .. "'")
