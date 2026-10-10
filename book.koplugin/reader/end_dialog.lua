--[[--
阅读结束动作：只提供返回主页和删除本书。

@module koplugin.book.reader.end_dialog
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")

---@class BookReaderEndDialog
local EndDialog = {}

---@param plugin table
---@param identity BookIdentity|nil
function EndDialog.show(plugin, identity)
    local function goHome()
        require("desktop").open(plugin)
    end
    --- 先确认，再关书回桌面（文件不能在打开状态下删），最后删并刷新书架。
    local function deleteBook()
        local source = identity and identity.source
        if not source then
            Toast:new{ text = _("当前数据源不支持删除本书") }:show()
            return
        end
        local title = identity.book and identity.book.title or identity.stable_id
        require("ui.themes.widgets.confirm"):new{
            text = T(_("确定删除《%1》？"), title),
            ok_text = _("删除"),
            ok_callback = function()
                require("desktop").open(plugin)
                source:deleteBookAsync(identity, function(ok, err)
                    if not ok then
                        Toast:new{ text = err or _("删除本书失败") }:show()
                        return
                    end
                    local desk = require("apps/filemanager/filemanager").instance.book.desktop
                    if desk and not desk.closed then desk:onEvent("shelf_changed") end
                end)
            end,
        }:show()
    end
    Sheet:new{
        title = _("本书已读完"),
        items = {
            { text = _("返回主页"), callback = goHome },
            { text = _("删除本书"), callback = deleteBook },
        },
    }:show()
end

return EndDialog
