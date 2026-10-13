--[[-- reader.context.pagesText：按页区间取全文（章节摘要用）；分页文档可只取两头。 --]]

local Assert = require("support.assert")
package.preload["reader.session"] = function()
    return { current = function() return { page = 1 } end }
end
local Context = require("reader.context")

-- 滚动文档：两页起点 xpointer 之间的文字
local asked
local rolling = {
    rolling = {},
    document = {
        getPageXPointer = function(_doc, page) return "xp" .. page end,
        getTextFromXPointers = function(_doc, from, to)
            asked = { from, to }
            return "  第一段\r\n第二段  "
        end,
    },
}
Assert.eq(Context.pagesText(rolling, 3, 9), "第一段\n第二段")
Assert.eq(asked[1], "xp3")
Assert.eq(asked[2], "xp9")

-- 分页文档：逐页拼接，跳过空页，不含 end_page
local paging = {
    document = {
        getTextBoxes = function(_doc, page)
            if page == 2 then return {} end
            return { { { word = "p" .. page } } }
        end,
    },
}
Assert.eq(Context.pagesText(paging, 1, 4), "p1\n\np3")

-- 分页文档给了开头 / 结尾上限：只取够两头，中间的页不碰
local touched = {}
paging.document.getTextBoxes = function(_doc, page)
    touched[#touched + 1] = page
    return { { { word = "p" .. page } } }
end
Assert.eq(Context.pagesText(paging, 1, 41, 4, 3), "p1\n\np2\n……\np40")
Assert.eq(table.concat(touched, ","), "1,2,40", "40 页的章只取了 3 页")
-- 两头相接：不加省略号，每页只取一次
touched = {}
Assert.eq(Context.pagesText(paging, 1, 4, 4, 100), "p1\n\np2\n\np3")
Assert.eq(table.concat(touched, ","), "1,2,3")

-- 空区间
Assert.eq(Context.pagesText(paging, 5, 5), "")
Assert.eq(Context.pagesText(rolling, 6, 2), "")

-- 文档取字抛错：当作没有文字
rolling.document.getTextFromXPointers = function() error("boom") end
Assert.eq(Context.pagesText(rolling, 1, 2), "")

return true
