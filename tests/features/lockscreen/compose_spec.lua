--[[--
features.lockscreen.compose：背景就绪后合成、取消，背景图与自绘铺底交给 render。

@module tests.features.lockscreen.compose_spec
--]]

local Assert = require("support.assert")

local asset_cb
local asset_cancelled
local ensure_mode = "async"
local render_calls
local render_background
local accent = 0
local ticks = {}
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    }
end
local function flush()
    while #ticks > 0 do table.remove(ticks, 1)() end
end
package.preload["ui.themes"] = function()
    return { current = function() return { color = { accent = accent } } end }
end

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
        dayKey = function() return "2026-10-26" end,
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
            render_background = background
            Assert.eq(blocks[1].text, "center-center")
            return true
        end,
    }
end

package.loaded["features.lockscreen.compose"] = nil
local Compose = require("features.lockscreen.compose")

local component = {
    id = "current",
    layout = "quote",
    blocks = function(position)
        return { { text = position } }
    end,
}

local function plan(asset)
    return {
        component = component,
        asset = asset or { id = "test" },
        position = "center-center",
        wide = true,
    }
end

-- 模式 / 主题色切换必须使已有 PNG 失效；灰度时改预设色不改变有效强调色。
local key_plan = plan()
local gray_key = Compose.dayKey(key_plan)
accent = 0x0756AD
local blue_key = Compose.dayKey(key_plan)
Assert.is_true(gray_key ~= blue_key)
accent = 0x7038A0
Assert.is_true(Compose.dayKey(key_plan) ~= blue_key)
accent = 0
Assert.eq(Compose.dayKey(key_plan), gray_key)

local function reset()
    asset_cb = nil
    asset_cancelled = false
    ensure_mode = "async"
    render_calls = 0
    render_background = nil
    ticks = {}
end

-- 异步背景：返回可取消任务，背景到了下一拍才渲染，只回调一次。
reset()
local results = {}
local job = Compose.build(plan(), function(ok, err)
    results[#results + 1] = { ok = ok, err = err }
end)
Assert.not_nil(job)
Assert.eq(render_calls, 0)
asset_cb("/tmp/background.png")
Assert.eq(render_calls, 0, "写盘在 nextTick")
flush()
Assert.eq(render_calls, 1)
Assert.eq(#results, 1)
Assert.is_true(results[1].ok)
Assert.eq(render_background.path, "/tmp/background.png")
Assert.is_nil(render_background.contain)
Assert.is_nil(render_background.blocks)

-- 本地背景 ensure 同步回调：仍返回可取消句柄，合成在下一拍。
reset()
ensure_mode = "success"
local sync_result
job = Compose.build(plan(), function(ok) sync_result = ok end)
Assert.not_nil(job)
Assert.eq(render_calls, 0)
flush()
Assert.eq(render_calls, 1)
Assert.is_true(sync_result)

-- 取消向背景任务传播，迟到回调不得渲染或通知调用方。
reset()
local cancelled_result
job = Compose.build(plan(), function(ok) cancelled_result = ok end)
assert(job).cancel()
Assert.is_true(asset_cancelled)
asset_cb("/tmp/background.png")
flush()
Assert.eq(render_calls, 0)
Assert.is_nil(cancelled_result)

-- 自绘背景（海报墙）拿整屏矩形出铺底块；contain 原样交给 render。
reset()
local backdrop_rect
job = Compose.build(plan({
    id = "wall",
    contain = true,
    blocks = function(rect)
        backdrop_rect = rect
        return { { text = "wall" } }
    end,
}), function() end)
asset_cb(nil)
flush()
Assert.eq(render_calls, 1)
Assert.eq(backdrop_rect.w, 480)
Assert.eq(backdrop_rect.h, 800)
Assert.is_nil(render_background.path)
Assert.is_true(render_background.contain)
Assert.eq(render_background.blocks[1].text, "wall")

-- 资源失败直接报错，不渲染。
reset()
ensure_mode = "error"
local failed, failure
job = Compose.build(plan(), function(ok, err)
    failed, failure = ok, err
end)
Assert.is_false(failed)
Assert.eq(failure, "asset failed")
Assert.eq(render_calls, 0)
