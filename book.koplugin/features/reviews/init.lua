--[[--
段评：阅读页标出他人段评较多的句子，点按查看。

数据接口归属主源；这里只装段落标记与章末入口，见 marks。

@module koplugin.book.features.reviews
--]]

require("l10n").apply()

local _ = require("gettext")
local Ext = require("utils.extension")
local Reviews = {}

Ext.add("desktop.comments", function(book, page)
    local items = {}
    for _idx, item in ipairs(page.items) do
        items[#items + 1] = {
            id = "", author = item.author or "", content = item.text or "",
            time = item.time or "", grade = item.grade, reply_to = item.reply_to,
            replies = 0,
        }
    end
    require("features.reviews.sheet"):new{
        title = page.title or _("书评"),
        snapshot = items,
        spot = { range = "", text = book.title, total = #items },
    }:show()
end)

Reviews.events = {
    --- 关书：取消在飞拉取 / 定位 / 预扫，回调不再落到已关的文档上。
    ---@param plugin BookPlugin
    CloseDocument = function(plugin)
        local marks = plugin.ui._book_reviews_marks
        if marks then marks:reset() end
    end,
}

---@param plugin BookPlugin
function Reviews.onReaderReady(plugin)
    require("features.reviews.marks").install(plugin.ui)
end

return Reviews
