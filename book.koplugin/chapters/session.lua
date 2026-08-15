--[[--
按章阅读会话状态。

@module koplugin.book.chapters.session
--]]

local Session = {
    _session = nil,
    _generation_counter = 0,
    --- 切章 switchDocument 期间：CloseDocument 应跳过 clear
    _pending_switch = nil,
}

--- 取当前会话表。
---@return table|nil
function Session.get()
    return Session._session
end

--- 是否有有效按章会话。
---@return boolean
function Session.isActive()
    local s = Session._session
    return s ~= nil and s.ref ~= nil
end

---@return number|nil
function Session.chapterCount()
    local s = Session._session
    if not s or type(s.toc) ~= "table" then
        return nil
    end
    return #s.toc
end

---@return number|nil
function Session.currentIdx()
    local s = Session._session
    return s and s.idx or nil
end

---@return BookChapter[]|nil
function Session.toc()
    local s = Session._session
    return s and s.toc or nil
end

---@return BookRef|nil
function Session.ref()
    local s = Session._session
    return s and s.ref or nil
end

---@return number
function Session.generation()
    local s = Session._session
    return (s and s.generation) or 0
end

--- 绑定按章阅读会话。
---@param opts table
function Session.bind(opts)
    Session._generation_counter = Session._generation_counter + 1
    Session._pending_switch = nil
    Session._session = {
        plugin = opts.plugin,
        source = opts.source,
        book = opts.book,
        ref = opts.ref,
        toc = opts.toc,
        idx = opts.idx or 1,
        generation = Session._generation_counter,
        --- 打开新章后应用的章内比例（0..1）；ReaderReady 消费
        pending_within = nil,
        --- next | prev | nil；ReaderReady 决定落点页
        open_direction = nil,
    }
end

--- 清除按章阅读会话。
function Session.clear()
    Session._session = nil
    Session._pending_switch = nil
end

--- 标记即将 switchDocument（真关书以外的换章）。
---@param path string
function Session.beginSwitch(path)
    Session._pending_switch = {
        path = path,
    }
end

--- CloseDocument 时：若是切章则消费 pending 并返回 true（勿 clear）。
---@param closed_path string|nil 即将关闭的文档路径（可选）
---@return boolean
function Session.consumeSwitch(closed_path)
    local p = Session._pending_switch
    if not p then
        return false
    end
    -- 切章会关旧文档再开新文档；pending 指向新 path
    if closed_path and p.path and closed_path == p.path then
        -- 异常：关的是新文档本身，仍算切章流程中
    end
    Session._pending_switch = nil
    return true
end

---@return boolean
function Session.hasPendingSwitch()
    return Session._pending_switch ~= nil
end

---@return string|nil
function Session.pendingSwitchPath()
    local p = Session._pending_switch
    return p and p.path or nil
end

function Session.clearPendingSwitch()
    Session._pending_switch = nil
end

return Session
