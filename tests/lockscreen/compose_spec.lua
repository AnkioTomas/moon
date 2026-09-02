--[[--
lockscreen.compose：资源与文案汇合、取消和 direct 资源。

@module tests.lockscreen.compose_spec
--]]

local Assert = require("support.assert")

local asset_cb
local asset_cancelled
local ensure_mode = "async"
local render_calls
local text_cb
local text_cancelled
local text_calls

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

package.preload["lockscreen.background"] = function()
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

package.preload["lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
        panel = function() return {} end,
    }
end

package.preload["lockscreen.components.base"] = function()
    return {
        find = function() return nil end,
    }
end

package.preload["lockscreen.render"] = function()
    return {
        write = function(_, background, blocks)
            render_calls = render_calls + 1
            Assert.eq(background, "/tmp/background.png")
            Assert.eq(blocks[1].text, "quote")
            return true
        end,
    }
end

package.loaded["lockscreen.compose"] = nil
local Compose = require("lockscreen.compose")

local component = {
    layout = "quote",
    blocks = function(_, _, text, source)
        return { { text = text .. source } }
    end,
    ensureText = function(cb)
        text_calls = text_calls + 1
        text_cb = cb
        return {
            cancel = function() text_cancelled = true end,
        }
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
    text_cb = nil
    text_cancelled = false
    text_calls = 0
end

-- 文案先完成不能提前渲染；背景随后完成时只渲染、回调一次。
reset()
local results = {}
local job = Compose.build(plan(false), function(ok, err, path)
    results[#results + 1] = { ok = ok, err = err, path = path }
end)
Assert.not_nil(job)
Assert.not_nil(asset_cb)
Assert.not_nil(text_cb)
text_cb("quo", "te")
Assert.eq(render_calls, 0)
asset_cb("/tmp/background.png")
Assert.eq(render_calls, 1)
Assert.eq(#results, 1)
Assert.is_true(results[1].ok)
Assert.is_nil(results[1].path)
asset_cb("/tmp/background.png")
text_cb("ignored", "")
Assert.eq(render_calls, 1)
Assert.eq(#results, 1)

-- 同步背景先完成时仍要等待异步文案。
reset()
ensure_mode = "success"
local sync_result
job = Compose.build(plan(false), function(ok) sync_result = ok end)
Assert.not_nil(job)
Assert.eq(render_calls, 0)
Assert.is_nil(sync_result)
text_cb("quo", "te")
Assert.eq(render_calls, 1)
Assert.is_true(sync_result)

-- 取消必须向两个子任务传播，迟到回调不得渲染或通知调用方。
reset()
local cancelled_result
job = Compose.build(plan(false), function(ok) cancelled_result = ok end)
assert(job).cancel()
Assert.is_true(asset_cancelled)
Assert.is_true(text_cancelled)
asset_cb("/tmp/background.png")
text_cb("quo", "te")
Assert.eq(render_calls, 0)
Assert.is_nil(cancelled_result)

-- direct 资源本身就是锁屏图，不得启动文案请求或渲染 compose.png。
reset()
local direct_path
job = Compose.build(plan(true), function(ok, err, path)
    Assert.is_true(ok)
    Assert.is_nil(err)
    direct_path = path
end)
Assert.not_nil(job)
Assert.eq(text_calls, 0)
asset_cb("/tmp/direct.png")
Assert.eq(direct_path, "/tmp/direct.png")
Assert.eq(render_calls, 0)

-- 同步资源失败应立即封口，不能继续启动无意义的文案任务。
reset()
ensure_mode = "error"
local failed, failure
job = Compose.build(plan(false), function(ok, err)
    failed, failure = ok, err
end)
Assert.is_nil(job)
Assert.is_false(failed)
Assert.eq(failure, "asset failed")
Assert.eq(text_calls, 0)
Assert.eq(render_calls, 0)
