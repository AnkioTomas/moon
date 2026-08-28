--[[-- 同步快捷动作。
@module koplugin.book.ui.panel.actions.sync
--]]

local UIManager = require("ui/uimanager")
local _ = require("gettext")

return {
    id = "sync",
    title = _("同步"),
    icon = "cloud_sync",
    scope = "reader",
    available = function(ctx)
        local current = require("ui.reader.session").current()
        return current and current.identity and current.identity.source ~= nil
    end,
    run = function(ctx)
        local ui = ctx and ctx.ui
        local current = require("ui.reader.session").current()
        local identity = current and current.identity
        local source = identity and identity.source
        if not ui or not identity or not source then return end
        require("book.progress").save(current, function(progress_ok)
            if not progress_ok then return end
            require("book.note").save(ui, identity, function(notes_ok)
                if not notes_ok then return end
                require("book.sync").runAsync(source, {
                    identity = identity,
                    skip_books = true,
                }, function(result, err)
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = result and _("同步完成")
                            or (err and tostring(err) or _("同步失败")),
                        timeout = 2,
                    })
                end)
            end)
        end)
    end,
}
