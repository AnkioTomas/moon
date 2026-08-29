--[[--
截图对话框的远程分享按钮。通过 ButtonDialog 构造点注入，不修改 KOReader 源码。

@module koplugin.book.ui.screenshot_share
--]]

require("l10n").apply()

local M = {}

--- KOReader 用 bidi isolate 包裹标题里的文件路径；这是展示标记，不能传给 realpath。
---@param path string
---@return string
local function rawPath(path)
    for _, mark in ipairs({ "\226\129\166", "\226\129\167", "\226\129\168", "\226\129\169" }) do
        path = path:gsub(mark, "")
    end
    return path
end

function M.install()
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
                            local UIManager = require("ui/uimanager")
                            local InfoMessage = require("ui/widget/infomessage")
                            -- 分享走局域网下载，只要求已拿到网络连接；不能用 isOnline，
                            -- 否则无外网/DNS 的局域网会被误判为不可分享。
                            if not require("ui/network/manager"):isConnected() then
                                UIManager:show(InfoMessage:new{
                                    text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3,
                                })
                                return
                            end
                            local Remote = require("remote.init")
                            local url, err = Remote.shareUrl(path)
                            if not url then
                                UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
                                return
                            end
                            -- 二维码是下一步页面，不能叠在仍占满屏幕的截图确认框上。
                            if screenshot_dialog and screenshot_dialog.onClose then
                                screenshot_dialog:onClose()
                            else
                                UIManager:close(screenshot_dialog)
                            end
                            local QRWidget = require("ui/widget/qrwidget")
                            local Screen = require("device").screen
                            local qr = QRWidget:new{
                                text = url,
                                width = math.floor(Screen:getWidth() * 0.65),
                                height = math.floor(Screen:getWidth() * 0.65),
                            }
                            local dialog
                            dialog = ButtonDialog:new{
                                title = _("通过远程管理分享"),
                                buttons = {{
                                    { text = _("关闭"), callback = function()
                                        UIManager:close(dialog)
                                    end },
                                }},
                            }
                            if dialog.addWidget then
                                dialog:addWidget(qr)
                            end
                            UIManager:show(dialog)
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
