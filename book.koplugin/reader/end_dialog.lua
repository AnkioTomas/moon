--[[--
阅读结束动作：返回主页、软删除（清正文、进度划线可恢复）、彻底删除。

@module koplugin.book.reader.end_dialog
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")

---@class BookReaderEndDialog
local EndDialog = {}

--- 桌面要等回桌面后才拿得到实例，关书之后再查。
local function refreshShelf()
    local desk = require("apps/filemanager/filemanager").instance.book.desktop
    if desk and not desk.closed then desk:onEvent("shelf_changed") end
end

---@param plugin table
---@param identity BookIdentity
function EndDialog.show(plugin, identity)
    local title = identity.book and identity.book.title or identity.stable_id
    local function goHome()
        require("desktop").open(plugin)
    end
    --- 软删除是纯本地操作，不依赖属主源：先确认，关书后清正文标隐藏并刷新书架。
    --- 缓存任务在跑时中止，别和落盘抢同一批文件。
    local function softDelete()
        require("ui.themes.widgets.confirm"):new{
            text = T(_("软删除《%1》？\n\n会清理：本地正文与章节缓存\n会保留：书目、封面、阅读进度、划线与笔记\n书从书架隐藏，筛选「软删除」可恢复；不影响云端。"), title),
            ok_text = _("软删除"),
            ok_callback = function()
                local key = "cache\0" .. identity.source_id .. "\0" .. identity.stable_id
                if require("workers.tasks").get(key) then
                    Toast:new{ text = _("本书正在后台缓存，请稍后再试") }:show()
                    return
                end
                require("desktop").open(plugin)
                if not require("book.store").softDelete(identity.source_id, identity.stable_id) then
                    Toast:new{ text = _("软删除失败") }:show()
                    return
                end
                Toast:new{ text = _("已软删除") }:show()
                refreshShelf()
            end,
        }:show()
    end
    --- 先确认，再关书回桌面（文件不能在打开状态下删），最后删并刷新书架。
    local function deleteBook()
        local source = identity.source
        if not source then
            Toast:new{ text = _("当前数据源不支持删除本书") }:show()
            return
        end
        require("ui.themes.widgets.confirm"):new{
            text = T(_("彻底删除《%1》？\n\n会清理：本地文件与缓存、书架条目、阅读进度、划线与笔记、统计\n有云端时下次同步也会从远端删除，无法从「软删除」筛选恢复。"), title),
            ok_text = _("删除"),
            ok_callback = function()
                require("desktop").open(plugin)
                source:deleteBookAsync(identity, function(ok, err)
                    if not ok then
                        Toast:new{ text = err or _("删除本书失败") }:show()
                        return
                    end
                    refreshShelf()
                end)
            end,
        }:show()
    end
    Sheet:new{
        title = _("本书已读完"),
        items = {
            { text = _("返回主页"), callback = goHome },
            { text = _("软删除（清本地正文，进度划线可恢复）"), callback = softDelete },
            { text = _("彻底删除（进度、划线与书架一并清除）"), callback = deleteBook },
        },
    }:show()
end

return EndDialog
