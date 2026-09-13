--[[--
共享引言块：大引号、正文、细线、一行署名。
@module tests.ui.views.quote_spec
--]]

local Assert = require("support.assert")

local function widget()
    return { new = function(_, opts)
        opts.getSize = function(self)
            return {
                w = self.width or self.max_width or (self.dimen and self.dimen.w) or 80,
                h = self.height or (self.dimen and self.dimen.h) or 16,
            }
        end
        opts.setText = function(self, text) self.text = text end
        return opts
    end }
end
for _, name in ipairs({
    "container/widgetcontainer", "container/framecontainer", "container/leftcontainer", "container/rightcontainer",
    "horizontalgroup", "horizontalspan", "verticalgroup", "verticalspan",
    "textwidget", "textboxwidget", "linewidget",
}) do package.preload["ui/widget/" .. name] = widget end
package.preload["ui/geometry"] = widget
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = 0 } end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        fontSize = function(n) return n end,
        line = function() return 1 end,
        face = function(_, size) return { size = size or 15 } end,
        muted = function() return 1 end,
        dim = function() return 2 end,
    }
end

local Quote = require("ui.views.quote")
local range = Quote.heightRange()
-- 桩：引号16 + 空隙2 + 正文40 + 线上下12 + 线1 + 署名16 = 87，再加默认内边距 16
Assert.eq(range.height, 103)
Assert.is_nil(range.min)
Assert.is_nil(range.max)

Assert.eq(Quote.attribution({ author = "陆游", title = "冬夜读书示子聿" }), "—— 陆游 · 冬夜读书示子聿")
Assert.eq(Quote.attribution({ source = "陆游" }), "—— 陆游")
Assert.eq(Quote.attribution({ source = "—— 已有前缀" }), "—— 已有前缀")

local parts = Quote:new{ data = {
    text = "纸上得来终觉浅",
    author = "陆游",
    title = "冬夜读书示子聿",
}, width = 320, height = 96, y = 10 }
parts:build()
Assert.eq(parts.body.text, "纸上得来终觉浅")
Assert.eq(parts.attr.text, "—— 陆游 · 冬夜读书示子聿")
Assert.eq(parts.height, 96)
Assert.eq(parts.body.width, 320 - 28)
Assert.eq(parts.body.height, math.floor(1.35 * 15 + 0.5) * 2)

parts:updateView({ text = "新句", author = "苏轼", title = "题西林壁" })
Assert.eq(parts.body.text, "新句")
Assert.eq(parts.attr.text, "—— 苏轼 · 题西林壁")

parts:updateView({ text = "只有作者", author = "朱熹" })
Assert.eq(parts.attr.text, "—— 朱熹")

local lock = Quote:new{ data = { text = "锁屏句", source = "出处" },
    width = 200,
    height = 200,
    body_size = 30,
    mark_size = 46,
    attr_size = 16,
    lines = 4,
    pad_x = 0,
}
lock:build()
Assert.eq(lock.attr.text, "—— 出处")
Assert.eq(lock.body.height, math.floor(1.35 * 30 + 0.5) * 4)

return true
