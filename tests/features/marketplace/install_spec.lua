--[[-- features.marketplace.install：多资产提取、计划校验、核心目录保护、安装结果回传。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["json"] = function() return require("support.json_stub") end
local downloaded = {}
package.preload["http.request"] = function()
    return {
        get = function() error("marketplace install 测试不得发真实请求") end,
        download = function(opts, dest)
            downloaded[#downloaded + 1] = { url = opts.url, dest = dest }
            error("marketplace install 测试必须注入 download")
        end,
    }
end
package.preload["workers.job"] = function()
    return {
        run = function() error("marketplace install 测试必须注入 run") end,
    }
end

local MarketInstall = require("features.marketplace.install")

local plugin = {
    uid = "github:Acme/nice-plugin",
    type = "github", host = "https://github.com", owner = "Acme", repo = "nice-plugin",
    title = "Nice", version = "1.2.0", release_tag = "v1.2.0",
    release_assets = {
        { name = "nice.koplugin-1.2.0.zip", url = "https://github.com/Acme/nice-plugin/releases/download/v1.2.0/nice.koplugin-1.2.0.zip" },
        { name = "extra.koplugin-1.2.0.zip", url = "https://github.com/Acme/nice-plugin/releases/download/v1.2.0/extra.koplugin-1.2.0.zip" },
        { name = "bad.zip", url = "javascript:alert(1)" },
    },
}

local assets = MarketInstall.assets(plugin)
Assert.eq(#assets, 2, "自动过滤非法协议资产，保留合法多包")
Assert.eq(assets[1].name, "nice.koplugin-1.2.0.zip")
Assert.eq(assets[2].name, "extra.koplugin-1.2.0.zip")

-- 兼容仅含 release_url / release_asset 的旧字段
local legacy_assets = MarketInstall.assets({
    release_asset = "one.zip",
    release_url = "https://github.com/Acme/one/releases/download/v1.0.0/one.zip",
})
Assert.eq(#legacy_assets, 1)
Assert.eq(legacy_assets[1].name, "one.zip")

local root = "/koreader/plugins/book.koplugin"
local plan, err = MarketInstall.plan(plugin, assets[1], root)
Assert.is_nil(err, err)
Assert.eq(plan.parent, "/koreader/plugins")
Assert.eq(plan.url, assets[1].url)
Assert.eq(plan.asset_name, "nice.koplugin-1.2.0.zip")
Assert.eq(plan.version, "1.2.0")
Assert.eq(plan.title, "Nice")
Assert.is_true(plan.digest_missing)

-- 拒绝非法文件名 / 非法 URL / 伪装 book.koplugin
local p_bad, e_bad = MarketInstall.plan(plugin, { name = "../evil.zip", url = assets[1].url }, root)
Assert.is_nil(p_bad)
Assert.eq(e_bad, "asset")

p_bad, e_bad = MarketInstall.plan(plugin, { name = "ok.zip", url = "file:///etc/passwd" }, root)
Assert.is_nil(p_bad)
Assert.eq(e_bad, "unsafe_url")

p_bad, e_bad = MarketInstall.plan({ uid = "x", repo = "book.koplugin" }, assets[1], root)
Assert.is_nil(p_bad)
Assert.eq(e_bad, "reserved")

-- perform：失败回传错误，成功回传真实安装的 .koplugin 目录名
local ran = {}
MarketInstall.perform(plan, {
    download = function(url, dest, cb)
        ran.url, ran.dest = url, dest
        cb(true)
        return { cancel = function() end }
    end,
    run = function() return nil, "not a koplugin archive" end,
}, function(ok, detail)
    ran.ok, ran.detail = ok, detail
end)
Assert.is_false(ran.ok)
Assert.eq(ran.detail, "not a koplugin archive")
Assert.eq(#downloaded, 0)

ran = {}
MarketInstall.perform(plan, {
    download = function(_url, _dest, cb) cb(true) return { cancel = function() end } end,
    run = function() return true, "nice.koplugin" end,
}, function(ok, detail)
    ran.ok, ran.detail = ok, detail
end)
Assert.is_true(ran.ok)
Assert.eq(ran.detail, "nice.koplugin")
Assert.eq(#downloaded, 0)

Assert.eq(MarketInstall.pluginsParent(root), "/koreader/plugins")
Assert.is_true(MarketInstall.isReservedName("book.koplugin"))

-- 取消打到当前下载，之后的完成回调不再回传；忙标记放开，下一次安装还能开始
ran = {}
local late
local handle = MarketInstall.perform(plan, {
    download = function(_url, _dest, cb)
        late = cb
        return { cancel = function() late = nil end }
    end,
    run = function() return true, "nice.koplugin" end,
}, function(ok, detail)
    ran.ok, ran.detail = ok, detail
end)
Assert.eq(type(handle.cancel), "function")
handle.cancel()
if late then late(true) end
Assert.is_nil(ran.ok, "取消后不得再回调")

ran = {}
MarketInstall.perform(plan, {
    download = function(_url, _dest, cb) cb(true) return { cancel = function() end } end,
    run = function() return true, "nice.koplugin" end,
}, function(ok, detail)
    ran.ok, ran.detail = ok, detail
end)
Assert.is_true(ran.ok, "取消后应能再次安装")
Assert.eq(ran.detail, "nice.koplugin")

return true
