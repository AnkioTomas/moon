--[[--
海报墙封面预取：书库里没开过的网络书没有本地封面，锁屏时不触网，只能占位。
联网时按属主源的 coverRequest 后台下载并落盘到封面缓存；全部结束且有新封面时
触发一次锁屏刷新（cache_key 里带封面到位标记，会重画）。休眠时无网就直接跳过，用占位。

@module koplugin.book.features.lockscreen.components.cover_prefetch
--]]

local logger = require("utils.log")

local M = {}

-- 本次运行已尝试过的书，失败也不重复下载（下载层自己还有失败退避）。
local tried = {}
local pending = 0
local landed = 0

--- 解析封面请求：先用库里的远程地址，否则问属主源。
---@param book table shelfBook
---@return table|nil req { url, headers }
local function request(book)
    if book.cover_url then return { url = book.cover_url } end
    local owner = require("source.registry").resolve(book.source_id)
    if owner and type(owner.coverRequest) == "function" then
        local ok, req = pcall(owner.coverRequest, owner, book)
        if not ok then
            logger.warn("book.lockscreen coverRequest failed", book.source_id, req)
        elseif type(req) == "table" and type(req.url) == "string"
            and req.url:match("^https?://") then
            return req
        end
    end
    return nil
end

local function finish()
    pending = pending - 1
    if pending > 0 or landed == 0 then return end
    landed = 0
    require("ui/uimanager"):nextTick(function()
        require("ui.guard").call("lockscreen.poster_cover",
            require("features.lockscreen").refresh, nil, false, "poster_cover")
    end)
end

--- 为缺封面的书发起后台下载；未联网时什么都不做。
---@param shelf table[] poster 书单（shelfBook）
function M.run(shelf)
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return end
    local Image = require("ui.themes.widgets.image")
    local Book = require("ui.widgets.book")
    for _idx, book in ipairs(shelf or {}) do
        local key = tostring(book.source_id) .. "\0" .. tostring(book.stable_id)
        if not book.cover and book.source_id and not tried[key] then
            tried[key] = true
            local req = request(book)
            if req then
                pending = pending + 1
                local started, start_err = pcall(Image.fetchAsync, req.url, req.headers, function(path, err)
                    if path then
                        Book.persistCover(book, path)
                        if require("features.lockscreen.components.library")
                            .coverPath(book.stable_id, book.source_id) then
                            landed = landed + 1
                        end
                    else
                        logger.dbg("book.lockscreen poster cover failed", book.stable_id, err)
                    end
                    finish()
                end)
                if not started then
                    logger.warn("book.lockscreen poster cover fetch failed", book.stable_id, start_err)
                    finish()
                end
            end
        end
    end
end

--- 测试用：清空已尝试记录。
function M._reset()
    tried, pending, landed = {}, 0, 0
end

return M
