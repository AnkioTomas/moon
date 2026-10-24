--[[--
KOReader 宿主版本门槛（插件 init 本地门禁，非网络更新检查）。

稳定月发号是 `vYYYY.MM`（无 point），归一为 `YYYYMM000000`；
`.1` 才是 `YYYYMM010000`。门槛必须对齐月发号，否则 `2026.07` 被误拒。

故意不叫 version.lua：会盖住 KOReader 自带的 `require("version")`。

@module koplugin.book.ko_version
--]]

local MIN_KOREADER_VERSION = 202607000000
local UIManager = require("ui/uimanager")
local Version = require("version")
local _ = require("gettext")

local M = {}

--- 当前 KOReader 是否满足月读最低版本。
---@return boolean
function M.supported()
    local current = Version:getNormalizedCurrentVersion()
    return current ~= nil and current >= MIN_KOREADER_VERSION
end

--- 版本不够时 main.lua 直接返回的占位插件：只弹一次提示。
--- 必须在 main.lua 其它 require 之前拦住：旧版 KOReader 缺 `ffi/posix` 等模块，
--- 业务模块顶层 require 就会抛错，init 里再检查已经晚了。
---@param WidgetContainer table
---@return table
function M.stub(WidgetContainer)
    local shown = false
    return WidgetContainer:extend{
        name = "book",
        init = function()
            if shown then return end
            shown = true
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：") .. Version:getShortVersion(),
            })
        end,
    }
end

return M
