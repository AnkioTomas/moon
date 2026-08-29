--[[--
翻译弹窗布局：保持与词典一致的单外框、内部分隔线风格。

@module tests.translate.popup_spec
--]]

local Assert = require("support.assert")

local function class(default_size)
    local C = {}
    function C:new(args)
        args = args or {}
        setmetatable(args, { __index = self })
        return args
    end
    function C:getSize()
        return self.dimen or default_size or { w = self.width or 0, h = self.height or 0 }
    end
    return C
end

local function container()
    local C = class()
    function C:getSize()
        local width, height = 0, 0
        for _, child in ipairs(self) do
            local size = child.getSize and child:getSize() or { w = child.width or 0, h = child.height or 0 }
            width = math.max(width, size.w or 0)
            height = height + (size.h or 0)
        end
        return self.dimen or { w = width, h = height }
    end
    return C
end

local frame_calls = {}
local FrameContainer = class()
function FrameContainer:new(args)
    frame_calls[#frame_calls + 1] = args
    return class({ w = 0, h = 0 }):new(args)
end

local InputContainer = {}
function InputContainer:extend(def)
    def.__index = def
    return setmetatable(def, { __index = self })
end
function InputContainer:new(args)
    setmetatable(args, { __index = self })
    args:init()
    return args
end

local Button = class({ w = 0, h = 24 })
function Button:getSize()
    return { w = self.width or 0, h = 24 }
end

local Span = class()
function Span:getSize()
    return { w = self.width or 0, h = 0 }
end

local HorizontalGroup = container()
function HorizontalGroup:getSize()
    local width, height = 0, 0
    for _, child in ipairs(self) do
        local size = child:getSize()
        width = width + (size.w or 0)
        height = math.max(height, size.h or 0)
    end
    return { w = width, h = height }
end

local CenterContainer = class()
local TextBoxWidget = class()
function TextBoxWidget:getSize()
    return { w = self.width, h = self.height }
end

local line_calls = {}
local LineWidget = class()
function LineWidget:new(args)
    line_calls[#line_calls + 1] = args
    return class(args.dimen):new(args)
end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = "black", COLOR_GRAY = "gray", COLOR_WHITE = "white" }
end
package.preload["device"] = function()
    return { hasClipboard = function() return false end, screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
    } }
end
package.preload["translate.edge"] = function() return {} end
package.preload["translate.languages"] = function()
    return { displayName = function(_, code) return code or "自动" end }
end
package.preload["ffi/util"] = function()
    return { template = function(text, ...)
        for i = 1, select("#", ...) do text = text:gsub("%%" .. i, tostring(select(i, ...)), 1) end
        return text
    end }
end
package.preload["ui/widget/button"] = function() return Button end
package.preload["ui/widget/buttontable"] = function() return class() end
package.preload["ui/widget/container/centercontainer"] = function() return CenterContainer end
package.preload["ui/widget/container/framecontainer"] = function() return FrameContainer end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end
package.preload["ui/widget/horizontalgroup"] = function() return HorizontalGroup end
package.preload["ui/widget/horizontalspan"] = function() return Span end
package.preload["ui/widget/verticalgroup"] = function() return container() end
package.preload["ui/widget/verticalspan"] = function() return Span end
package.preload["ui/widget/linewidget"] = function() return LineWidget end
package.preload["ui/widget/textboxwidget"] = function() return TextBoxWidget end
package.preload["ui/widget/titlebar"] = function()
    local TitleBar = class({ w = 0, h = 30 })
    function TitleBar:getSize() return { w = self.width, h = 30 } end
    return TitleBar
end
package.preload["ui/geometry"] = function() return { new = function(_, dimen) return dimen end } end
package.preload["ui/size"] = function()
    return {
        padding = { default = 10, small = 4 },
        radius = { window = 0 },
        border = { window = 2 },
        line = { medium = 1 },
    }
end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/uimanager"] = function() return {} end
package.preload["ui.components.popup"] = function() return {} end

local Popup = require("translate.popup")
local popup = Popup.TranslatePopup:new{
    translator = {},
    text = "原文",
    source_lang = "zh",
    target_lang = "ko",
    translated = "译文",
}

Assert.eq(#frame_calls, 1, "译文区域不得额外嵌套边框")
Assert.eq(popup.text_box.width, popup.width - 20)
Assert.eq(#line_calls, 2)
Assert.eq(line_calls[1].background, "black")
Assert.eq(line_calls[2].background, "gray")
