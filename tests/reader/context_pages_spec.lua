--[[-- reader.context.pagesText：按页区间取全文（章节摘要用）；分页文档可只取两头。 --]]

local Assert = require("support.assert")
package.preload["reader.session"] = function()
    return { current = function() return { page = 1 } end }
end
local Context = require("reader.context")

-- 滚动文档：逐页取本页与下一页起点 xpointer 之间的文字
local asked = {}
local rolling = {
    rolling = {},
    document = {
        getPageXPointer = function(_doc, page) return "xp" .. page end,
        getTextFromXPointers = function(_doc, from, to)
            asked[#asked + 1] = from .. "-" .. to
            return "  " .. from .. "\r\n段  "
        end,
    },
}
Assert.eq(Context.pagesText(rolling, 3, 5), "xp3\n段\n\nxp4\n段")
Assert.eq(table.concat(asked, ","), "xp3-xp4,xp4-xp5")
-- 给了开头 / 结尾上限：大章不再整段读进内存，只取两头几页
asked = {}
Assert.eq(Context.pagesText(rolling, 1, 1001, 4, 4), "xp1\n段\n……\nxp1000\n段")
Assert.eq(table.concat(asked, ","), "xp1-xp2,xp1000-xp1001", "1000 页的章只取了 2 页")

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
Assert.eq(Context.pagesText(rolling, 1, 3), "")

return true
