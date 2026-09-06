--[[-- Pager.pack：末页只剩一行时不能丢；首页 7 个组件必须都能翻到。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, a, b)
        return (text:gsub("%%1", tostring(a)):gsub("%%2", tostring(b)))
    end }
end
package.preload["ui/bidi"] = function()
    return { mirroredUILayout = function() return false end }
end
package.preload["ui/widget/button"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/bottomcontainer"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/topcontainer"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/horizontalgroup"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/horizontalspan"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/verticalgroup"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/widget/verticalspan"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 1 }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end } }
end
package.preload["ui.components.bookui"] = function()
    return {
        iconSz = function() return 24 end,
        sz = function(n) return n end,
        fontSize = function(n) return n end,
    }
end

local Pager = require("ui.components.pager")

local function box(id, h)
    return {
        id = id,
        getSize = function() return { w = 100, h = h } end,
    }
end

local function ids(page)
    local out = {}
    for _, w in ipairs(page) do
        out[#out + 1] = w.id
    end
    return out
end

-- 前 6 个刚好一页，第 7 个单独一页：以前 #cur==1 会被丢掉。
local rows = {}
for i = 1, 7 do
    rows[i] = box("c" .. i, 46)
end
local pages = Pager.pack(rows, 46 * 6)
Assert.eq(#pages, 2)
Assert.eq(table.concat(ids(pages[1]), ","), "c1,c2,c3,c4,c5,c6")
Assert.eq(table.concat(ids(pages[2]), ","), "c7")

-- 单件比页高：仍保留，不另开空页。
local tall = Pager.pack({ box("tall", 200) }, 50)
Assert.eq(#tall, 1)
Assert.eq(tall[1][1].id, "tall")

-- 空列表也要有一页，桌面分页带才能站住。
local empty = Pager.pack({}, 100)
Assert.eq(#empty, 1)
Assert.eq(#empty[1], 0)

return true
