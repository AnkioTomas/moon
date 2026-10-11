--[[--
主体：摸鱼日报。日报图片直接作为全屏背景。

@module koplugin.book.features.lockscreen.components.myrl
--]]

local _ = require("gettext")

return {
    id = "myrl",
    label = _("摸鱼日报"),
    supports_position = false,
    uses_background = false,
    asset = {
        id = "myrl",
        path = function() return require("online.myrl"):imageFile() end,
        endpoint = "myrl",
        direct = true,
        network = true,
    },
}
