--[[--
段评：阅读页标出他人段评较多的句子，点按查看。

数据与开关归属主源（目前只有微信读书，开关在微信读书设置页），这里只装阅读页标记，见 marks。

@module koplugin.book.features.reviews
--]]

local Reviews = {}

---@param plugin BookPlugin
function Reviews.onReaderReady(plugin)
    require("features.reviews.marks").install(plugin.ui)
end

return Reviews
