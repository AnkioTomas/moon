--[[--
KOReader 版本门槛。

稳定月发号是 `vYYYY.MM`（无 point），归一为 `YYYYMM000000`；
`.1` 才是 `YYYYMM010000`。门槛必须对齐月发号，否则 `2026.07` 被误拒。

@module version.adapter
--]]

local MIN_KOREADER_VERSION = 202607000000
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

function M.checkKOReaderVersion()
    local ok, Version = pcall(require, "version")
    local current = ok and Version and Version:getNormalizedCurrentVersion()
    if type(current) == "number" and current >= MIN_KOREADER_VERSION then
        return true
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local display = ok and Version and Version.getShortVersion and Version:getShortVersion() or _("未知")
    if type(current) == "number" then
        display = tostring(display) .. " (" .. tostring(current) .. ")"
    end
    UIManager:show(ConfirmBox:new {
        text = _("月读需要 KOReader 2026.07 或更高版本。\n\n当前版本：") .. tostring(display),
        ok_text = _("关闭"),
    })
    return false
end

return M
