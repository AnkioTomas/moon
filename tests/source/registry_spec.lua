--[[--
source.registry 离线用例

@module tests.source.registry_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["utils.settings"] = function()
    local common = { active_source = "moon" }
    return {
        get = function()
            return common
        end,
        save = function() end,
        getSource = function()
            return { url = "http://x", token = "t", username = "u", password = "p" }
        end,
    }
end

-- 避免真实 HTTP 构造
package.preload["source.moon.client"] = function()
    local C = {}
    function C:new()
        return setmetatable({ configured = function() return true end }, { __index = C })
    end
    function C:configured() return true end
    return C
end
package.preload["source.moon.mapper"] = function()
    return { list = function() return { data = {}, count = 0 } end }
end
package.preload["source.wechat.auth"] = function()
    return { hasSession = function() return true end }
end
package.preload["source.wechat.client"] = function()
    local C = {}
    function C:new() return setmetatable({}, { __index = C }) end
    return C
end
package.preload["source.wechat.mapper"] = function() return {} end
package.preload["source.wechat.chapter"] = function()
    return { ensure = function() return true end }
end
package.preload["source.fanqie.settings"] = function()
    return {
        new = function()
            return {
                is_cookie_configured = function() return false end,
            }
        end,
    }
end
package.preload["source.fanqie.client"] = function()
    local C = {}
    function C:new() return setmetatable({}, { __index = C }) end
    return C
end
package.preload["workers.job"] = function()
    return {
        run = function(_, opts)
            if opts and opts.on_done then opts.on_done({}) end
            return { cancel = function() end }
        end,
    }
end
package.preload["source.fanqie.content"] = function() return {} end
package.preload["source.toc"] = function()
    return { read = function() return nil end, put = function() end, index = function() end }
end

-- 清掉可能缓存的模块
package.loaded["source.registry"] = nil
package.loaded["source.moon"] = nil
package.loaded["source.wechat"] = nil
package.loaded["source.fanqie"] = nil

local Registry = require("source.registry")

do
    local list = Registry.list()
    Assert.eq(list[1].id, "local", "本地排源列表第一（选择器混合置顶后为第二）")
    local ids = {}
    for _, m in ipairs(list) do
        ids[m.id] = true
    end
    Assert.is_true(ids.moon)
    Assert.is_true(ids.wechat)
    Assert.is_true(ids.jdread)
    Assert.is_true(ids.copymanga)
    Assert.is_true(ids.fanqie)
    Assert.is_true(ids["local"])
end

do
    local src, err = Registry.create("local")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "local")
    Assert.eq(src.type, "book")
    local caps = src:capabilities()
    Assert.is_true(caps.scrape)
    Assert.is_true(caps.edit)
    Assert.is_nil(caps.whole_book)
    Assert.is_true(type(src.coverRequest) == "function")
    Assert.is_false(src:configured())
end

do
    local src, err = Registry.create("moon")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "moon")
    Assert.eq(src.type, "book")
    local caps = src:capabilities()
    Assert.is_true(caps.stats_pull)
    Assert.is_false(caps.scrape)
    Assert.is_false(caps.edit)
end

-- 隐藏源（订阅）：能 meta / create，不进源清单。
do
    Registry.registerHidden("hidden_x", function()
        return { meta = function() return { id = "hidden_x", name = "x", type = "chapter" } end,
            new = function() return { id = "hidden_x" } end }
    end)
    Assert.eq(Registry.meta("hidden_x").type, "chapter")
    Assert.eq(Registry.create("hidden_x").id, "hidden_x")
    for _idx, meta in ipairs(Registry.list()) do Assert.is_true(meta.id ~= "hidden_x", "不进清单") end
end

do
    Assert.eq(Registry.meta("wechat").type, "chapter")
    Assert.eq(Registry.meta("jdread").type, "chapter")
    Assert.eq(Registry.meta("copymanga").type, "chapter")
    Assert.eq(Registry.meta("fanqie").type, "chapter")
end

do
    local src, err = Registry.create("jdread")
    Assert.is_true(src ~= nil, err)
    local caps = src:capabilities()
    Assert.is_false(caps.stats_pull)
    Assert.is_false(type(src.pushStatsAsync) == "function")
end

do
    local src, err = Registry.create("wechat")
    Assert.is_true(src ~= nil, err)
    Assert.is_false(src:capabilities().scrape)
    Assert.is_true(src:capabilities().edit)
end

do
    local src, err = Registry.create("fanqie")
    Assert.is_true(src ~= nil, err)
    Assert.eq(src.id, "fanqie")
    Assert.is_false(src:capabilities().stats_pull)
end

do
    local src, err = Registry.create("copymanga")
    Assert.is_true(src ~= nil, err)
    Assert.is_true(src:configured())
    Assert.is_false(src:capabilities().stats_pull)
end

do
    local src, err = Registry.create("nope")
    Assert.is_nil(src)
    Assert.is_true(type(err) == "string")
end

-- 启用源：默认全开；禁用/启用非活跃源；活跃源禁止禁用
do
    -- 无 enabled_sources（旧配置）：全真，listEnabled == list
    Assert.is_true(Registry.isEnabled("wechat"))
    Assert.is_true(Registry.isEnabled("moon"))
    Assert.eq(#Registry.listEnabled(), #Registry.list())

    -- 禁用非活跃源：首次写入以全开初始化集合
    Assert.is_true(Registry.setEnabled("wechat", false))
    Assert.is_false(Registry.isEnabled("wechat"))
    Assert.eq(#Registry.listEnabled(), #Registry.list() - 1)

    -- 再启用回来
    Assert.is_true(Registry.setEnabled("wechat", true))
    Assert.is_true(Registry.isEnabled("wechat"))
    Assert.eq(#Registry.listEnabled(), #Registry.list())

    -- 活跃源（stub 固定 moon）禁止禁用；isEnabled 兜底恒 true
    local ok, err = Registry.setEnabled("moon", false)
    Assert.is_false(ok)
    Assert.not_nil(err)
    Assert.is_true(Registry.isEnabled("moon"))

    -- 未知源
    Assert.is_false(Registry.setEnabled("nope", true))
end

-- 非活跃属主源复用，并在注册表作废时恰好释放一次。
do
    Registry.invalidate()
    local original_create = Registry.create
    local created, closed = {}, {}
    Registry.create = function(id)
        created[id] = (created[id] or 0) + 1
        return {
            id = id,
            close = function()
                closed[id] = (closed[id] or 0) + 1
            end,
        }
    end

    local first = Registry.resolve("wechat")
    local second = Registry.resolve("wechat")
    Assert.eq(first, second)
    Assert.eq(created.wechat, 1)
    Assert.is_nil(created.moon)

    -- 活跃源与属主源共用缓存：current() 拿到的就是 resolve(activeId) 那个实例
    Assert.eq(Registry.current(), Registry.resolve("moon"))
    Assert.eq(created.moon, 1)

    -- 换源不关旧实例（可能仍是打开中书籍的属主源），只复用缓存
    local common = require("utils.settings").get("source")
    Assert.eq(Registry.setActive("wechat"), first)
    Assert.eq(Registry.current(), first)
    Assert.is_nil(closed.moon)
    common.active_source = "moon"

    Registry.invalidate()
    Assert.eq(closed.wechat, 1)
    Assert.eq(closed.moon, 1)
    Assert.is_true(Registry.resolve("wechat") ~= first)
    Assert.eq(created.wechat, 2)
    Registry.invalidate()
    Registry.create = original_create

    -- 未知源：不进缓存，不改配置
    local src, err = Registry.setActive("nope")
    Assert.is_nil(src)
    Assert.not_nil(err)
    Assert.eq(common.active_source, "moon")
end

-- 源模块加载失败是代码缺陷：直接抛出，不从列表里悄悄藏掉。
do
    package.loaded["source.jdread"] = nil
    package.preload["source.jdread"] = function() error("boom") end
    Assert.errors(function() Registry.meta("jdread") end)
    Assert.errors(function() Registry.list() end)
    package.preload["source.jdread"] = nil
    package.loaded["source.jdread"] = nil
end

Assert.is_nil(Registry.meta("nope"))

-- 活跃源已下线（旧配置存着 kindle）：退回 local，不卡在「未知数据源」。
do
    local common = require("utils.settings").get("source")
    local saved = common.active_source
    common.active_source = "kindle"
    Assert.eq(Registry.activeId(), "local")
    for _, m in ipairs(Registry.list()) do
        Assert.is_true(m.id ~= "kindle")
    end
    common.active_source = saved
    Assert.eq(Registry.activeId(), saved)
end

-- 清理 preload，避免污染后续用例
for _, k in ipairs({
    "utils.settings",
    "source.moon.client",
    "source.moon.mapper",
    "source.wechat.auth",
    "source.wechat.client",
    "source.wechat.mapper",
    "source.wechat.chapter",
    "source.registry",
    "source.moon",
    "source.wechat",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
