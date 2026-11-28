--[[-- features.marketplace.catalog：刷新与本地缓存、失败保留旧列表、离线搜索/分类/生态筛选。 --]]

local Assert = require("support.assert")
local Config = require("support.config")

if not Config.available() then
    Assert.skip("沙箱数据目录未就绪，请用 ./tests/run.sh 运行")
end

package.preload["json"] = function() return require("support.json_stub") end
package.preload["http.request"] = function()
    return {
        get = function(_url, _opts, cb)
            cb(nil, "network", { code = 0 })
            return { cancel = function() end }
        end,
    }
end

local Client = require("features.marketplace.client")
local Catalog = require("features.marketplace.catalog")

local function resetAll()
    Catalog.clear()
end

resetAll()

local p1 = {
    uid = "github:Acme/stats",
    type = "github", host = "https://github.com", owner = "Acme", repo = "stats",
    kind = "moon", kinds = { "moon" },
    title = "阅读统计", summary = "统计你的阅读时长", version = "1.2.0",
    category = "reader", category_name = "阅读增强",
    tags = { "统计" }, topics = { "moon-plugin" },
    updated_at = 1000,
    release_tag = "v1.2.0", release_asset = "stats.koplugin-1.2.0.zip",
    release_url = "https://github.com/Acme/stats/releases/download/v1.2.0/stats.koplugin-1.2.0.zip",
    release_assets = {
        { name = "stats.koplugin-1.2.0.zip", url = "https://github.com/Acme/stats/releases/download/v1.2.0/stats.koplugin-1.2.0.zip" },
    },
}
local p2 = {
    uid = "github:Beta/chess",
    type = "github", host = "https://github.com", owner = "Beta", repo = "chess",
    kind = "koreader", kinds = { "koreader" },
    title = "Chess", summary = "Play chess on e-ink", version = "2.0.0",
    category = "game", category_name = "游戏",
    tags = { "棋类" }, topics = { "koreader-plugin" },
    updated_at = 2000,
}

Client.listCategories = function(cb)
    cb({
        { code = "reader", name = "阅读增强" },
        { code = "game", name = "游戏" },
    }, nil)
    return { cancel = function() end }
end
Client.listPlugins = function(cb, progress)
    if progress then progress(2, 2) end
    cb({ p1, p2 }, nil)
    return { cancel = function() end }
end

local err, progress_n = nil, 0
Catalog.refresh(function(refresh_err)
    err = refresh_err
end, {
    on_progress = function(done, total)
        Assert.eq(done, 2)
        Assert.eq(total, 2)
        progress_n = progress_n + 1
    end,
})
Assert.is_nil(err)
Assert.eq(progress_n, 1)
Assert.eq(#Catalog.categories(), 2)
Assert.eq(Catalog.categoryName("reader"), "阅读增强")
Assert.eq(Catalog.count(), 2)
Assert.eq(Catalog.count("阅读"), 1)
Assert.eq(Catalog.count("", "game"), 1)
Assert.eq(Catalog.count("", "", "moon"), 1)
local idx_all = Catalog.listIndex()
Assert.eq(#idx_all, 2)
Assert.eq(idx_all[1].uid, p2.uid, "列表应按 updated_at 倒序排列，最新更新的在前")
Assert.eq(idx_all[2].uid, p1.uid)
Assert.is_true(idx_all[1].has_sub)
Assert.eq(Catalog.get(p1.uid).title, "阅读统计")

-- 离线搜索 × 分类 × 生态筛选（全走 SQLite）
-- 先验证刷新失败保留旧缓存
Client.listPlugins = function(cb)
    cb(nil, "network")
    return { cancel = function() end }
end
Catalog.refresh(function(refresh_err)
    err = refresh_err
end)
Assert.eq(err, "network")
Assert.eq(#Catalog.plugins(), 2)

local found = Catalog.filter("阅读", "", "")
Assert.eq(#found, 1)
Assert.eq(found[1].uid, p1.uid)
found = Catalog.filter("CHESS", "", "")
Assert.eq(#found, 1)
Assert.eq(found[1].uid, p2.uid)
found = Catalog.filter("", "game", "")
Assert.eq(#found, 1)
Assert.eq(found[1].uid, p2.uid)
found = Catalog.filter("", "", "moon")
Assert.eq(#found, 1)
Assert.eq(found[1].uid, p1.uid)
found = Catalog.filter("", "", "koreader")
Assert.eq(#found, 1)
Assert.eq(found[1].uid, p2.uid)
found = Catalog.filter("chess", "reader", "")
Assert.eq(#found, 0)

-- mergeDetail 合并 meta 与 release_assets 回本地索引
Assert.is_true(Catalog.mergeDetail({
    uid = p1.uid,
    default_branch = "main",
    meta = { name = "stats", version = "1.3.0" },
    version = "1.3.0",
    updated_at = 3000,
    readme = { name = "README.md", text = "not stored in catalog" },
}))
Assert.eq(Catalog.plugins()[1].uid, p1.uid, "updated_at 变大后应自动排到最前")
Assert.eq(Catalog.plugins()[1].version, "1.3.0")
Assert.eq(Catalog.plugins()[1].default_branch, "main")
Assert.is_nil(Catalog.plugins()[1].readme)

-- 字段无变化时 mergeDetail 不写库
Assert.is_false(Catalog.mergeDetail({
    uid = p1.uid,
    default_branch = "main",
    meta = { name = "stats", version = "1.3.0" },
    version = "1.3.0",
    updated_at = 3000,
    readme = { name = "README.md", text = "changed readme only" },
}), "详情字段未变化时不应写库")

-- 并发刷新取消上一轮；取消后迟到回调不得写回
local cancelled_first = false
local pending_cb
Client.listCategories = function(cb) cb({}, nil) return { cancel = function() end } end
Client.listPlugins = function(cb)
    pending_cb = cb
    return { cancel = function() cancelled_first = true end }
end
local finished = false
Catalog.refresh(function() finished = true end)
Catalog.refresh(function() finished = true end)
Assert.is_true(cancelled_first)
Catalog.cancel()
pending_cb({ p2 })
Assert.is_false(finished)
Assert.is_false(Catalog.isRefreshing())
Assert.eq(#Catalog.plugins(), 2, "取消后的迟到回调不得覆盖缓存")

-- 写入时自动忽略无 uid 的非法条目
Catalog.saveCache({ updated_at = 1, plugins = { { owner = "old", repo = "legacy" } } })
Assert.eq(Catalog.count(), 0)

-- #169 回归：meta 是函数（非表）时取版本不崩，降级到其他字段
Assert.is_nil(Catalog.catalogVersion({ meta = function() end }))
Assert.eq(Catalog.catalogVersion({ meta = function() end, release_tag = "v2.0.0" }), "2.0.0")
Assert.eq(Catalog.catalogVersion({ meta = { version = "3.1" } }), "3.1")
Assert.eq(Catalog.catalogVersion({ version = "0.0.1", release_tag = "v0.3.0" }), "0.3.0",
    "release 比目录 version 新时以 release 为准")
Assert.eq(Catalog.catalogVersion({ version = "3.1", release_tag = "v1.0.0" }), "3.1",
    "更旧的 release tag 不把版本号拉回去")

resetAll()
return true
