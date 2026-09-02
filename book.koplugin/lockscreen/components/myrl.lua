--[[--
主体：摸鱼日报。日报图片直接作为全屏背景。

@module koplugin.book.lockscreen.components.myrl
--]]

local _ = require("gettext")
local Background = require("lockscreen.background")
local Layout = require("lockscreen.layout")
local Paths = require("utils.paths")

return {
    id = "myrl",
    label = _("摸鱼日报"),
    supports_position = false,
    uses_background = false,
    asset = Background.daily{
        id = "myrl",
        path = function() return Paths.screensaverDir() .. "/myrl.png" end,
        direct = true,
        request = function()
            local w, h = Layout.portraitSize()
            return {
                url = string.format(
                    "https://api.ankio.net/myrl?ink=1&width=%d&height=%d", w, h
                ),
                method = "GET",
                timeout = 60,
            }
        end,
    },
}
