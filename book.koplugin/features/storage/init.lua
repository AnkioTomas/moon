--[[--
存储告急提醒：桌面打开后，数据目录所在分区可用空间低于 500MB 就弹一次窗（每个进程一次）。

封面缓存、书库与日志都落在数据目录；分区写满后 sqlite 写入会报 disk is full，所以要在写满之前告诉用户。

@module koplugin.book.features.storage
--]]

require("l10n").apply()

local _ = require("gettext")
local T = require("ffi/util").template

local Storage = {
    LOW_BYTES = 500 * 1024 * 1024,
    _warned = false,
}

--- 可用空间不足时弹窗；取不到空间（df 失败）不提醒。
---@return boolean shown
function Storage.check()
    if Storage._warned then return false end
    local available = require("util").diskUsage(require("datastorage"):getDataDir()).available
    if not available or available >= Storage.LOW_BYTES then return false end
    Storage._warned = true
    require("ui.themes.widgets.confirm"):new{
        title = _("存储空间不足"),
        text = T(_("设备可用空间只剩 %1 MB，继续使用可能导致书库写入失败。请清理不用的书籍或缓存。"),
            math.floor(available / 1024 / 1024)),
        ok_text = _("知道了"),
        cancel_text = _("忽略"),
    }:show()
    return true
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
require("utils.extension").add("desktop.opened", function() Storage.check() end)

return Storage
