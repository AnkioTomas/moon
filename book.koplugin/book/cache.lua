--[[--
缓存文件管理：后台分 tick 删目录、子进程用的同步遍历。

  只管 `.moon/cache/` 下的落盘文件；书籍身份与元数据门面在 book.store。

@module koplugin.book.book.cache
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("utils.log")
local UIManager = require("ui/uimanager")

local Cache = {}

local BUDGET = 32

--- 协作式递归遍历：一个 UI 周期最多处理 BUDGET 个目录项，剩余排到下一 tick。
--- 文件在遇到时回调，目录在其子项全部处理完后回调（自底向上，便于删除）。
--- visit 返回 false/nil 时立即终止，done(false, err)。
---@param root string
---@param visit fun(path: string, attr: table): boolean|nil, string|nil
---@param done fun(ok: boolean, err: string|nil)
local function walkAsync(root, visit, done)
    local stack = {}
    --- lfs.dir 返回 (iter, dir_obj)；必须成对保存，调用 iter(dir_obj)。
    local function push(path, attr)
        local iter, state = lfs.dir(path)
        if type(iter) == "function" and state ~= nil then
            stack[#stack + 1] = { path = path, attr = attr, iter = iter, state = state }
        end
    end
    local root_attr = lfs.attributes(root)
    if root_attr and root_attr.mode == "directory" then push(root, root_attr) end

    local function step()
        for _step = 1, BUDGET do
            local top = stack[#stack]
            if not top then break end
            local name = top.iter(top.state)
            local ok, err = true, nil
            if not name then
                table.remove(stack)
                ok, err = visit(top.path, top.attr)
            elseif name ~= "." and name ~= ".." then
                local path = top.path .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    push(path, attr)
                elseif attr then
                    ok, err = visit(path, attr)
                end
            end
            if not ok then
                done(false, err)
                return
            end
        end
        if #stack == 0 then
            done(true)
        else
            UIManager:nextTick(require("ui.guard").wrap("book cache", step))
        end
    end
    UIManager:nextTick(require("ui.guard").wrap("book cache", step))
end

--- 同步递归遍历，只给子进程用（主线程禁用：大目录会卡 UI）；visit 只收文件。
---@param root string
---@param visit fun(path: string, attr: table)
function Cache.walkFiles(root, visit)
    local stack = { root }
    while #stack > 0 do
        local dir = table.remove(stack)
        local iter, state = lfs.dir(dir)
        if type(iter) == "function" then
            for name in iter, state do
                if name ~= "." and name ~= ".." then
                    local path = dir .. "/" .. name
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "directory" then
                        stack[#stack + 1] = path
                    elseif attr then
                        visit(path, attr)
                    end
                end
            end
        end
    end
end

--- 后台分 tick 删除一个已脱离书库的目录（删书时改名移走的工作目录）；失败只记日志。
--- 连删几本书时会有几趟同时清同一个 `.trash`：别人先删掉的路径不算失败。
---@param dir string
function Cache.purgeAsync(dir)
    walkAsync(dir, function(path)
        local ok, err = os.remove(path)
        if ok or not lfs.attributes(path, "mode") then return true end
        return false, err
    end, function(ok, err)
        if not ok then logger.warn("book cache trash purge failed", dir, err) end
    end)
end

return Cache
