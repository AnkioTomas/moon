--[[--
.moon-koreader/sync.lck：上一台顺利写完的设备和时间。

没有 syncing.lock。两台同时写时后写的赢。能不能信远端多出来的文件，跟静读天下的书目谱系一样：
远端更新，或同一时间同一台设备，才信。更旧，或同一时间另一台设备各写一份，不信。
没有时间的旧内容没有谱系，照旧信任。

静读天下自己的锁在书库根或 .Moon+，这里不碰。

@module koplugin.book.moon_sync.lock
--]]

local Lock = {
    DONE = "sync.lck",
}

--- 第一行的设备 id。空文件当成没有。
---@param content string|nil
---@return string|nil
function Lock.owner(content)
    if type(content) ~= "string" then return nil end
    local id = content:match("^[ \t]*([^\r\n]*)")
    id = id and id:match("^[ \t]*(.-)[ \t]*$")
    if not id or id == "" then return nil end
    return id
end

--- 第二行的写入时间。没有这行就是旧格式。
---@param content string|nil
---@return integer|nil
function Lock.since(content)
    if type(content) ~= "string" then return nil end
    return tonumber(content:match("^[^\r\n]*\r?\n[ \t]*(%d+)"))
end

---@param device string
---@param now integer
---@return string
function Lock.encode(device, now)
    return device .. "\n" .. tostring(now) .. "\n"
end

--- 远端 sync.lck 能不能信。known 是这台设备上次收下或写出的内容。
--- 没有本地记录、或远端没有时间：照旧信任。
---@param remote string|nil
---@param known string|nil
---@return boolean
function Lock.trusted(remote, known)
    local remote_time, known_time = Lock.since(remote), Lock.since(known)
    if not remote_time or not known_time then return true end
    if remote_time > known_time then return true end
    if remote_time == known_time and Lock.owner(remote) == Lock.owner(known) then return true end
    return false
end

return Lock
