--[[-- features.marketplace.readme：经 moon-store 详情接口取回 README 与 meta，按 uid 缓存、离线回落。 --]]

local Assert = require("support.assert")
local Config = require("support.config")
if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["json"] = function() return require("support.json_stub") end
package.preload["http.request"] = function()
    return { get = function() error("readme 测试不得请求网络") end }
end

local Client = require("features.marketplace.client")
local Catalog = require("features.marketplace.catalog")
local Readme = require("features.marketplace.readme")

Readme.clearCache()
Catalog.clear()

local plugin = {
    uid = "github:Acme/nice-plugin",
    type = "github",
    host = "https://github.com",
    owner = "Acme",
    repo = "nice-plugin",
    title = "Nice",
}
Catalog.saveCache({ updated_at = os.time(), categories = {}, plugins = { plugin } })

local calls = 0
Client.getDetail = function(uid, cb)
    calls = calls + 1
    Assert.eq(uid, plugin.uid)
    cb({
        uid = uid,
        type = "github",
        owner = "Acme",
        repo = "nice-plugin",
        default_branch = "main",
        meta = { name = "nice", version = "1.0.0" },
        readme = { name = "README.zh-CN.md", text = "# 你好\n简介" },
    }, nil)
    return { cancel = function() end }
end

local got, got_err
Readme.fetch(plugin, function(item, err) got, got_err = item, err end)
Assert.is_nil(got_err)
Assert.eq(calls, 1)
Assert.eq(got.name, "README.zh-CN.md")
Assert.is_true(got.text:find("你好", 1, true) ~= nil)
Assert.is_nil(got.detail.readme, "detail 不应重复保存 readme 正文")
Assert.eq(Readme.pendingCount(), 0, "完成后应清理在途任务引用")
Assert.eq(Catalog.plugins()[1].default_branch, "main", "详情应顺带合并回目录索引")

-- 命中缓存不再请求网络
Client.getDetail = function() error("缓存命中时不应再请求详情") end
local cached
Readme.fetch(plugin, function(item) cached = item end)
Assert.eq(cached.text, got.text)

-- 目录升级到新版本后，旧 README 缓存按版本失效；在线拉新、离线回落旧缓存
local upgraded = {
    uid = plugin.uid,
    type = "github",
    host = "https://github.com",
    owner = "Acme",
    repo = "nice-plugin",
    title = "Nice",
    version = "2.0.0",
}
Assert.is_nil(Readme.get(upgraded), "目录版本升级后旧 README 缓存应判定失效")
Client.getDetail = function(_uid, cb)
    cb(nil, "network")
    return { cancel = function() end }
end
local offline_stale
Readme.fetch(upgraded, function(item, err)
    Assert.is_nil(err)
    offline_stale = item
end)
Assert.eq(offline_stale.text, got.text, "离线拉新失败时仍回落旧缓存")

local fetched_new = 0
Client.getDetail = function(uid, cb)
    fetched_new = fetched_new + 1
    cb({
        uid = uid, type = "github", owner = "Acme", repo = "nice-plugin",
        version = "2.0.0",
        readme = { name = "README.md", text = "# v2 新说明" },
    }, nil)
    return { cancel = function() end }
end
local fresh
Readme.fetch(upgraded, function(item, err)
    Assert.is_nil(err)
    fresh = item
end)
Assert.eq(fetched_new, 1)
Assert.eq(fresh.text, "# v2 新说明")
Assert.not_nil(Readme.get(upgraded))

-- 强制刷新失败时回落旧缓存
Client.getDetail = function(_uid, cb)
    cb(nil, "network")
    return { cancel = function() end }
end
local fallback
Readme.fetch(upgraded, function(item, err)
    Assert.is_nil(err)
    fallback = item
end, { force = true })
Assert.eq(fallback.text, fresh.text)

-- 无缓存失败返回错误
Readme.clearCache()
local fail_err
Readme.fetch(plugin, function(item, err)
    Assert.is_nil(item)
    fail_err = err
end)
Assert.eq(fail_err, "network")
Assert.eq(Readme.pendingCount(), 0)

-- 取消后迟到回调不交付，且清理任务引用
local late_cb, delivered
Client.getDetail = function(_uid, cb)
    late_cb = cb
    return { cancel = function() end }
end
local job = Readme.fetch(plugin, function(item) delivered = item end)
Assert.eq(Readme.pendingCount(), 1)
job.cancel()
Assert.eq(Readme.pendingCount(), 0)
late_cb({ uid = plugin.uid, readme = { name = "README.md", text = "late" } }, nil)
Assert.is_nil(delivered)

-- 独立文件 + 内存淘汰后仍可从磁盘命中
Client.getDetail = function(uid, cb)
    cb({ uid = uid, readme = { name = "README.md", text = "body:" .. uid } }, nil)
    return { cancel = function() end }
end
for i = 1, 20 do
    Readme.fetch({ uid = "github:Acme/p" .. i }, function() end)
end
local from_disk = Readme.get({ uid = "github:Acme/p1" })
Assert.not_nil(from_disk)
Assert.eq(from_disk.text, "body:github:Acme/p1")

Readme.clearCache()
Catalog.clear()
return true
