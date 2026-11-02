--[[--
X-Ray 订阅的数据事件（由 utils.event 扫描登记）。

改身份和撕墓碑都进 XrayDB 那一份表名单。撕墓碑走 removeIdentity，不走 reset：
reset 会自己 BEGIN，而 book_removed 已经跑在 BookDB.remove 的事务里。

@module koplugin.book.features.xray.events
--]]

local XrayDB = require("features.xray.db")

return {
    book_identity_changed = function(source_id, old_stable_id, new_stable_id, merge)
        return XrayDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    end,
    book_removed = function(source_id, stable_id)
        return XrayDB.removeIdentity(source_id, stable_id)
    end,
}
