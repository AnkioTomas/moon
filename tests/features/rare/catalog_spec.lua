--[[-- features.rare.catalog：清单、下载、类型开关过滤 active、两份释义互斥、warm。 --]]

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
local settings = {
    rare_lexicons = {}, rare_built_at = {},
    rare_ruby = true, rare_wordwise = true, rare_enabled = true,
    rare_split_migrated = true,
}
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
            local id = spec.name:match("^rare%.(.+)$")
            if id == "en-gloss-zh" or id == "en-gloss-en" then
                f:write("#lang=en\n#kind=wordwise\nfoo\t短义\t30000\n")
            elseif id == "en-ipa" then
                f:write("#lang=en\n#kind=ruby\nfoo\t/fu:/\t30000\n")
            else
                f:write("#lang=zh\n龘\tdá\t9000\n")
            end
            f:close()
            spec.on_installed({ built_at = "v1" })
            cb(true)
        end,
    }
end

package.loaded["features.rare"] = nil
package.loaded["features.rare.init"] = nil
local Catalog = require("features.rare.catalog")

do
    Assert.is_false(Catalog.installed("zh-pinyin"))
    Assert.len(Catalog.active(), 0)
    local ok
    Catalog.download("zh-pinyin", function(r) ok = r end)
    Assert.is_true(ok)
    Assert.is_true(Catalog.installed("zh-pinyin"))
    Assert.is_true(Catalog.enabled("zh-pinyin"))
    local active = Catalog.active()
    Assert.len(active, 1)
    Assert.eq(active[1].entries["龘"][1], "dá")
    Assert.eq(active[1].kind, "ruby")
end

do
    local f = assert(io.open(Catalog.dir() .. "/my-words.tsv", "wb"))
    f:write("#lang=en\nfoo\t/fu:/\t30000\n")
    f:close()
    Catalog.setEnabled("my-words", true)
    Assert.len(Catalog.active(), 2)
    Catalog.setEnabled("my-words", false)
    Assert.len(Catalog.active(), 1)
end

do
    -- 拼音与释义可并存；两份释义互斥；关 rare_wordwise 后 active 只剩 ruby。
    Catalog.download("en-gloss-zh", function() end)
    Assert.is_true(Catalog.enabled("en-gloss-zh"))
    Assert.is_true(Catalog.enabled("zh-pinyin"))
    Assert.len(Catalog.active(), 2)
    Catalog.download("en-gloss-en", function() end)
    Assert.is_nil(settings.rare_lexicons["en-gloss-zh"])
    Assert.len(Catalog.active(), 2)
    settings.rare_wordwise = false
    Assert.len(Catalog.active(), 1)
    Assert.eq(Catalog.active()[1].kind, "ruby")
    settings.rare_wordwise = true
end

do
    local f = assert(io.open(Catalog.path("warm-only"), "wb"))
    f:write("#lang=en\nzzz\t/z/\t9\n")
    f:close()
    settings.rare_lexicons["warm-only"] = true
    Assert.eq(Catalog.warm(), 1)
    Assert.eq(Catalog.warm(), 0)
    Catalog.delete("warm-only")
end

do
    Catalog.delete("zh-pinyin")
    Catalog.delete("en-gloss-zh")
    Catalog.delete("en-gloss-en")
    Assert.len(Catalog.active(), 0)
end

os.execute("rm -rf " .. TMP)
