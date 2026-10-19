--[[--
截图对话框的远程分享按钮。通过 ButtonDialog 构造点注入，不修改 KOReader 源码。

@module koplugin.book.features.remote.screenshot
--]]

require("l10n").apply()

---@class BookRemoteScreenshot
local M = {}

--- KOReader 用 bidi isolate 包裹标题里的文件路径；这是展示标记，不能传给 realpath。
---@param path string
---@return string
local function rawPath(path)
    for _idx, mark in ipairs({ "\226\129\166", "\226\129\167", "\226\129\168", "\226\129\169" }) do
        path = path:gsub(mark, "")
    end
    return path
end

--- 经远程管理把本地文件分享为局域网下载链接，弹二维码。
---@param path string 要分享的本地文件
---@param on_url fun()|nil 拿到链接、弹二维码之前调用（让出全屏的上一步页面）
function M.share(path, on_url)
    local _ = require("gettext")
    -- 分享走局域网下载，只要求已拿到网络连接（没连时先问是否开 Wi-Fi）；
    -- 不能用 isOnline，否则无外网/DNS 的局域网会被误判为不可分享。
    require("ui/network/manager"):runWhenConnected(function()
        local url, err = require("features.remote").shareUrl(path)
        if not url then
            require("ui.themes.widgets.toast"):new{ text = tostring(err), timeout = 3 }:show()
            return
        end
        if on_url then on_url() end
        require("ui.themes.widgets.qr"):new{ title = _("通过远程管理分享"), text = url }:show()
    end)
end

--- 挂截图确认框的「通过远程管理分享」按钮（幂等）。
function M.onCreate()
    local ButtonDialog = require("ui/widget/buttondialog")
    if ButtonDialog._book_share_patched then
        return
    end
    ButtonDialog._book_share_patched = true
    local original = ButtonDialog.new
    local _ = require("gettext")
    local screenshot_title = _("Screenshot saved to:")
    ButtonDialog.new = function(class, opts)
        local screenshot_dialog
        if type(opts) == "table" and type(opts.title) == "string"
            and opts.title:find(screenshot_title, 1, true)
            and type(opts.buttons) == "table" then
            local path = opts.title:match("\n\n([^\n]+)\n$")
            path = path and rawPath(path) or nil
            if path and path ~= "" then
                opts.buttons[#opts.buttons + 1] = {
                    {
                        text = _("通过远程管理分享"),
                        callback = function()
                            -- 二维码是下一步页面，不能叠在仍占满屏幕的截图确认框上。
                            require("ui.guard").call("remote share", M.share, path, function()
                                if screenshot_dialog and screenshot_dialog.onClose then
                                    screenshot_dialog:onClose()
                                else
                                    require("ui/uimanager"):close(screenshot_dialog)
                                end
                            end)
                        end,
                    },
                }
            end
        end
        screenshot_dialog = original(class, opts)
        return screenshot_dialog
    end
end

return M
