--[[--
按章源：章节序号 → 章 uid，再交给调用方开请求。

起点 / 晋江段评共用；错误文案由源传入。

@module koplugin.book.source.with_chapter_uid
--]]

local M = {}

--- identity.chapter_idx → toc[idx].uid → start(uid, cb)。
---@param source table 有 loadTocAsync
---@param identity BookIdentity
---@param missing_err string 目录缺该章时的错误文案
---@param start fun(chapter_uid: string, finish: fun(value: any, err: string|nil)): { cancel: fun() }|nil
---@param cb fun(value: any, err: string|nil)
---@return { cancel: fun() }
function M.run(source, identity, missing_err, start, cb)
    local cancelled, job = false, nil
    job = source:loadTocAsync(identity, function(toc, err)
        if cancelled then return end
        local chapter = toc and toc[tonumber(identity.chapter_idx)]
        if not chapter then
            cb(nil, err or missing_err)
            return
        end
        job = start(chapter.uid, cb)
    end)
    return { cancel = function()
        cancelled = true
        if job then job.cancel() end
    end }
end

return M
