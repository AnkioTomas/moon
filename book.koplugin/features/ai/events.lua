--[[--
书籍身份变更与数据清理后中止旧摘要请求；快照由核心 SummaryDB 同事务迁移、清理。

@module koplugin.book.features.ai.events
--]]

local Tasks = require("workers.tasks")

return {
    book_identity_changed = function(source_id, old_stable_id)
        Tasks.cancelPrefixed("ai_summary\0" .. source_id .. "\0" .. old_stable_id)
        return true
    end,
    book_removed = function(source_id, stable_id)
        Tasks.cancelPrefixed("ai_summary\0" .. source_id .. "\0" .. stable_id)
        return true
    end,
    source_forgotten = function(source_id)
        Tasks.cancelPrefixed("ai_summary\0" .. source_id)
        return true
    end,
    source_reading_cleared = function(source_id)
        require("features.ai.summary").cancelMissing(source_id)
        return true
    end,
}
