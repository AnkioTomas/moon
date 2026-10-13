--[[--
X-Ray 订阅的数据事件（由 utils.event 扫描登记）。

@module koplugin.book.features.xray.events
--]]

local DB = require("utils.db")
require("features.xray.db")

return {
    book_identity_changed = function(source_id, old_stable_id, new_stable_id, merge)
        return DB.moveIdentity("xray_entities", source_id, old_stable_id, new_stable_id, merge)
            and DB.moveIdentity("xray_scan", source_id, old_stable_id, new_stable_id, merge)
    end,
    book_removed = function(source_id, stable_id)
        return DB.removeIdentity("xray_entities", source_id, stable_id)
            and DB.removeIdentity("xray_scan", source_id, stable_id)
    end,
}
