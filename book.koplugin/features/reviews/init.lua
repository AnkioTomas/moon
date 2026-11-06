--[[--
段评：阅读页标出他人段评较多的句子，点按查看。

数据接口归属主源；这里只装段落标记与章末入口，见 marks。

@module koplugin.book.features.reviews
--]]

local Reviews = {}

---@param plugin BookPlugin
function Reviews.onReaderReady(plugin)
    require("features.reviews.marks").install(plugin.ui)
end

return Reviews
