--[[--
同步阻塞操作期间的忙碌窗：kamare 的缓存操作直接写盘，主线程会停住。
先把窗画出来、强制重绘一次，再动手；返回后关窗。

调用方只给标题与要跑的函数；`fn` 的返回值原样透传（最多四个）。
关闭失败不会发生：窗在建好后才交给 UIManager。

@module source.kavita.busy
--]]

local _ = require("gettext")

local Busy = {}

---@param title string 窗标题（一般是动作名，如「清理已读」）
---@param fn fun(): any
---@return any, any, any, any
function Busy.run(title, fn)
    local UIManager = require("ui/uimanager")
    local dialog = require("ui.themes.widgets.progress_dialog"):new{
        title = title,
        text = _("正在清理…"),
        dismissable = false,
    }
    local ok, code, message, detail = dialog:showWhile(function()
        if UIManager.forceRePaint then UIManager:forceRePaint() end
        return fn()
    end)
    dialog:close()
    return ok, code, message, detail
end

return Busy
