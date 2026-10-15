--[[-- features.rare.catalog：清单（含自制词库）、下载落位后启用、加载缓存、停用、删除。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

local TMP = Config.dir() .. "/.moon/cache/test_rare_catalog"
os.execute("rm -rf " .. TMP)
os.execute("mkdir -p " .. TMP)
package.preload["datastorage"] = function()
    return { getDataDir = function() return TMP .. "/data" end }
end
local settings = { rare_lexicons = {}, rare_built_at = {} }
package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "features.rare"); return settings end,
        save = function(name) assert(name == "features.rare") end,
    }
end
local spec_seen
package.preload["features.ime.download"] = function()
    return {
        install = function(spec, cb)
            spec_seen = spec
            local f = assert(io.open(spec.dest, "wb"))
            f:write("#lang=zh\n龘\tdá\t9000\n")
            f:close()
            spec.on_installed({ built_at = "v1" })
            cb(true)
        end,
    }
end

local Catalog = require("features.rare.catalog")

do
    Assert.is_false(Catalog.installed("zh-pinyin"))
    Assert.len(Catalog.active(), 0)
    local ok
    Catalog.download("zh-pinyin", function(r) ok = r end)
    Assert.is_true(ok)
    Assert.matches(spec_seen.base_path, "^assets/rare/zh%-pinyin$")
    Assert.eq(spec_seen.dest, Catalog.path("zh-pinyin"))
    Assert.is_true(Catalog.installed("zh-pinyin"))
    Assert.is_true(Catalog.enabled("zh-pinyin"))
    Assert.eq(settings.rare_built_at["zh-pinyin"], "v1")
    local active = Catalog.active()
    Assert.len(active, 1)
    Assert.eq(active[1].entries["龘"][1], "dá")
    -- 缓存：文件不变返回同一对象。
    Assert.eq(Catalog.load("zh-pinyin"), active[1])
end

do
    -- 目录里的自制词库出现在清单末尾；内置清单在前。
    local f = assert(io.open(Catalog.dir() .. "/my-words.tsv", "wb"))
    f:write("#lang=en\nfoo\t/fu:/\t30000\n")
    f:close()
    local list = Catalog.list()
    Assert.eq(list[1].id, "zh-pinyin")
    Assert.eq(list[#list].id, "my-words")
    Assert.is_true(list[#list].custom)
    Catalog.setEnabled("my-words", true)
    Assert.len(Catalog.active(), 2)
    Catalog.setEnabled("my-words", false)
    Assert.is_nil(settings.rare_lexicons["my-words"])
    Assert.len(Catalog.active(), 1)
end

do
    Catalog.delete("zh-pinyin")
    Assert.is_false(Catalog.installed("zh-pinyin"))
    Assert.is_nil(settings.rare_built_at["zh-pinyin"])
    Assert.len(Catalog.active(), 0)
end

os.execute("rm -rf " .. TMP)
