--[[--
月读同步里不碰网络的决定：谁的文件该上传、阅读数据能不能盖本地。

@module koplugin.book.moon_sync.plan
--]]

local Plan = {}

local PREFIXES = { "settings/", "secrets/", "fonts/" }

--- 远端相对路径必须落在三个允许的目录里，且不能跳出。
---@param rel string
---@return boolean
function Plan.safeRel(rel)
    if type(rel) ~= "string" or rel == "" or rel:find("\0", 1, true) then return false end
    if rel:sub(1, 1) == "/" then return false end
    for part in rel:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    for _idx, prefix in ipairs(PREFIXES) do
        if rel:sub(1, #prefix) == prefix and #rel > #prefix then return true end
    end
    return false
end

--- 按内容哈希和修改时间决定上传还是下载。哈希相同就不动。
--- 只在远端有的文件下载；只在本地有的上传。时间相同但哈希不同时本地赢。
--- trusted 为假：这份远端清单比本地见过的更旧，或是另一台设备从同一时间分出去的。
--- 本地文件不下载覆盖，远端多出来的也不拉（调用方把它们留在清单里）。
---@param local_map table<string, { hash: string, mtime: number }>
---@param remote_map table<string, { hash: string, mtime: number }>
---@param trusted boolean|nil 缺省信任
---@return string[] upload
---@return string[] download
function Plan.files(local_map, remote_map, trusted)
    if trusted == nil then trusted = true end
    local upload, download, seen = {}, {}, {}
    for rel, local_file in pairs(local_map) do
        seen[rel] = true
        local remote = remote_map[rel]
        if not remote then
            upload[#upload + 1] = rel
        elseif remote.hash ~= local_file.hash then
            if trusted and (local_file.mtime or 0) < (remote.mtime or 0) then
                download[#download + 1] = rel
            else
                upload[#upload + 1] = rel
            end
        end
    end
    for rel in pairs(remote_map) do
        if not seen[rel] and trusted then download[#download + 1] = rel end
    end
    table.sort(upload)
    table.sort(download)
    return upload, download
end

--- 远端阅读数据能不能盖过本地这一行。本地还有没推上去的改动时不盖。
---@param local_row { updated_at: number, sync_status: integer }|nil
---@param remote_row { updated_at: number }|nil
---@return boolean
function Plan.shouldApply(local_row, remote_row)
    if type(remote_row) ~= "table" then return false end
    if local_row == nil then return true end
    if tonumber(local_row.sync_status) == 0 then return false end
    return (tonumber(remote_row.updated_at) or 0) > (tonumber(local_row.updated_at) or 0)
end

return Plan
