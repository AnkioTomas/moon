--[[--
features.lockscreen.compose：背景就绪后合成、取消和 direct 资源。

@module tests.features.lockscreen.compose_spec
--]]

local Assert = require("support.assert")

local asset_cb
local asset_cancelled
local ensure_mode = "async"
local render_calls

package.preload["utils.paths"] = function()
    return {
        screensaverDir = function() return "/tmp/moon-compose" end,
        ensureScreensaverDir = function() end,
    }
end

package.preload["utils.settings"] = function()
    return {
        get = function() return {} end,
    }
end

package.preload["features.lockscreen.background"] = function()
    return {
        ensure = function(_, cb)
            asset_cb = cb
            if ensure_mode == "error" then
                cb(nil, "asset failed")
                return nil
            elseif ensure_mode == "success" then
                cb("/tmp/background.png")
                return nil
            end
            return {
                cancel = function() asset_cancelled = true end,
            }
        end,
        invalidate = function() end,
    }
end

package.preload["features.lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
        panel = function() return {} end,
    }
end

package.preload["features.lockscreen.components.base"] = function()
    return {
        find = function() return nil end,
    }
end

package.preload["features.lockscreen.render"] = function()
    return {
        write = function(_, background, blocks)
            render_calls = render_calls + 1
            Assert.eq(background, "/tmp/background.png")
            Assert.eq(blocks[1].text, "center-center")
            return true
        end,
    }
end

package.loaded["features.lockscreen.compose"] = nil
local Compose = require("features.lockscreen.compose")

local component = {
    layout = "quote",
    blocks = function(position)
        return { { text = position } }
    end,
}

local function plan(direct)
    return {
        component = component,
        asset = { id = "test", direct = direct },
        position = "center-center",
        wide = true,
    }
end

local function reset()
    asset_cb = nil
    asset_cancelled = false
    ensure_mode = "async"
    render_calls = 0
end

-- 异步背景：返回可取消任务，背景到了才渲染，只回调一次。
reset()
local results = {}
local job = Compose.build(plan(false), function(ok, err, path)
    results[#results + 1] = { ok = ok, err = err, path = path }
end)
Assert.not_nil(job)
Assert.eq(render_calls, 0)
asset_cb("/tmp/background.png")
Assert.eq(render_calls, 1)
Assert.eq(#results, 1)
Assert.is_true(results[1].ok)
Assert.is_nil(results[1].path)

-- 同步背景：当场合成，没有任务可取消。
reset()
ensure_mode = "success"
local sync_result
job = Compose.build(plan(false), function(ok) sync_result = ok end)
Assert.is_nil(job)
Assert.eq(render_calls, 1)
Assert.is_true(sync_result)

-- 取消向背景任务传播，迟到回调不得渲染或通知调用方。
reset()
local cancelled_result
job = Compose.build(plan(false), function(ok) cancelled_result = ok end)
assert(job).cancel()
Assert.is_true(asset_cancelled)
asset_cb("/tmp/background.png")
Assert.eq(render_calls, 0)
Assert.is_nil(cancelled_result)

-- direct 资源本身就是锁屏图，不渲染 compose.png。
reset()
local direct_path
job = Compose.build(plan(true), function(ok, err, path)
    Assert.is_true(ok)
    Assert.is_nil(err)
    direct_path = path
end)
Assert.not_nil(job)
asset_cb("/tmp/direct.png")
Assert.eq(direct_path, "/tmp/direct.png")
Assert.eq(render_calls, 0)

-- 资源失败直接报错，不渲染。
reset()
ensure_mode = "error"
local failed, failure
job = Compose.build(plan(false), function(ok, err)
    failed, failure = ok, err
end)
Assert.is_nil(job)
Assert.is_false(failed)
Assert.eq(failure, "asset failed")
Assert.eq(render_calls, 0)
