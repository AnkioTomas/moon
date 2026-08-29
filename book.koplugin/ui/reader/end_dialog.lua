--[[--
阅读结束动作：只提供返回主页和删除本书。

@module koplugin.book.ui.reader.end_dialog
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local EndDialog = {}

---@param plugin table
---@param ui table
---@param identity BookIdentity|nil
function EndDialog.show(plugin, ui, identity)
    local dialog
    local function close()
        if dialog then
            UIManager:close(dialog)
            dialog = nil
        end
    end
    local function goHome()
        close()
        if plugin and type(plugin.openDesktop) == "function" then
            plugin:openDesktop()
        elseif ui and ui.onClose then
            ui:onClose()
        end
    end
    local function deleteBook()
        close()
        local source = identity and identity.source
        if not source or type(source.deleteBookAsync) ~= "function" then
            UIManager:show(InfoMessage:new{ text = _("当前数据源不支持删除本书") })
            return
        end
        source:deleteBookAsync(identity, function(ok, err)
            if not ok then
                UIManager:show(InfoMessage:new{ text = err or _("删除本书失败") })
                return
            end
            if plugin and type(plugin.openDesktop) == "function" then
                plugin:openDesktop()
            elseif ui and ui.onClose then
                ui:onClose()
            end
        end)
    end
    dialog = ButtonDialog:new{
        title = _("本书已读完"),
        title_align = "center",
        buttons = {
            { { text = _("返回主页"), callback = goHome } },
            { { text = _("删除本书"), callback = deleteBook } },
        },
    }
    UIManager:show(dialog)
end

return EndDialog
