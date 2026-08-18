--[[--
lockscreen.styles.quote：高亮优先、一言协议与缓存回退。

@module tests.lockscreen.styles.quote_spec
--]]

local Assert = require("support.assert")
local rendered = {}
local settings = { lock_screen_quote_mode = "hitokoto" }
local highlight
local response = [[{"code":200,"data":{"hitokoto":"接口一言","from":"测试出处","from_who":"测试作者"}}]]
local requests = 0
local decoded = { code = 200, data = { hitokoto = "接口一言", from = "测试出处", from_who = "测试作者" } }

package.preload["lockscreen.background"] = function()
    return { ensure = function(cb) cb("/bg.png") end }
end
package.preload["lockscreen.context"] = function()
    return { highlight = function() return highlight end }
end
package.preload["lockscreen.render"] = function()
    return {
        size = function() return 480, 800 end,
        measureText = function(text, _, size) return math.ceil(#text / 8) * size end,
        write = function(path, bg, blocks)
            rendered = { path = path, bg = bg, blocks = blocks }
            return true
        end,
    }
end
package.preload["http.request"] = function()
    return { get = function(_, _, cb) requests = requests + 1; cb(response) end }
end
package.preload["json"] = function()
    return {
        decode = function()
            return decoded
        end,
    }
end
package.preload["utils.paths"] = function()
    return { lockScreenDir = function() return "/lock" end }
end
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
package.preload["ffi/util"] = function()
    return { template = function(s) return s end }
end
package.loaded["lockscreen.styles.quote"] = nil

local Quote = require("lockscreen.styles.quote")
local done
Quote.fetch(function(ok) done = ok end)
Assert.is_true(done)
Assert.eq(settings.lock_screen_quote_cache, "接口一言")
Assert.eq(settings.lock_screen_quote_source_cache, "测试作者 · 测试出处")
Assert.eq(rendered.blocks[3].text, "接口一言")
Assert.eq(rendered.blocks[5].text, "测试作者 · 测试出处")
Assert.eq(rendered.blocks[1].kind, "panel")
Assert.is_true(rendered.blocks[1].height >= math.floor(800 * 0.32))
local short_height = rendered.blocks[1].height

decoded = { data = { hitokoto = string.rep("这是一段较长的一言。", 12) } }
done = nil
Quote.fetch(function(ok) done = ok end)
Assert.is_true(done)
Assert.is_true(rendered.blocks[1].height > short_height)
Assert.is_true(rendered.blocks[3].size <= 34)

highlight = "我的高亮"
settings.lock_screen_quote_mode = "highlight"
response = nil
done = nil
Quote.fetch(function(ok) done = ok end)
Assert.is_true(done)
Assert.eq(rendered.blocks[3].text, "我的高亮")

highlight = nil
done = nil
Quote.fetch(function(ok) done = ok end)
Assert.is_true(done)
Assert.eq(rendered.blocks[3].text, "读书不觉已春深，一寸光阴一寸金。")
Assert.eq(requests, 2)
