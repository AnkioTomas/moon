--[[--
把漫画书源下载的一章页图打成 CBZ（zip，store 模式），成功后删掉散页图。
组装时经 source.cbz_fit 按屏宽缩小并把条漫切成独立页；已有 CBZ 不检查、不重切。

切片、打包在 workers.job（heavy）子进程里同步跑，不共用父进程 writer。
子进程只写 .part，父进程完成后放到最终路径；取消时杀掉子进程并清理临时文件。

@module koplugin.book.source.cbz
--]]

local Fit = require("source.cbz_fit")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Cbz = {}

--- 文件存在且非空。
---@param path string
---@return boolean
function Cbz.ready(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and (tonumber(attr.size) or 0) > 0
end

---@param writer ArchiverWriter
---@param path string
---@param name string
---@return boolean
---@return string|nil
local function addFile(writer, path, name)
    local file, err = io.open(path, "rb")
    if not file then return false, err or _("无法读取漫画图片") end
    local data = file:read("*a")
    file:close()
    if not writer:addFileFromMemory(name, data) then
        return false, writer.err or _("无法写入漫画文件")
    end
    return true
end

---@param dir string
local function removeDir(dir)
    pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
        end
        lfs.rmdir(dir)
    end)
end

--- 清掉打包留下的半截文件与切片目录。可重复调用。
---@param archive_path string|nil
function Cbz.clearWork(archive_path)
    if type(archive_path) ~= "string" or archive_path == "" then return end
    os.remove(archive_path .. ".part")
    removeDir(archive_path:gsub("%.cb[zt]$", "") .. ".fit")
end

--- 取消进行中的打包：杀掉 Job 子进程，并在父进程清理临时文件。
---@param state table|nil
---@param archive_path string
function Cbz.abort(state, archive_path)
    if type(state) == "table" then
        if state._aborted then
            Cbz.clearWork(archive_path)
            return
        end
        state._aborted = true
        state.cancelled = true
        local job = state.job
        state.job = nil
        state.writer = nil
        if job and job.cancel then job:cancel() end
    end
    Cbz.clearWork(archive_path)
end

---@param state table
---@param archive_path string
---@param job table
local function attachJob(state, archive_path, job)
    state.job = job
    -- 兼容漫画源已有的 writer:close() 取消入口；父进程不持有真正的 Writer。
    state.writer = {
        close = function()
            Cbz.abort(state, archive_path)
        end,
    }
end

---@param progress fun(value: any)|nil
---@param done integer
---@param total integer
---@param last integer|nil
---@return integer|nil
local function report(progress, done, total, last)
    if not progress or total < 1 then return last end
    local percent = math.floor(done * 100 / total)
    if percent == last then return last end
    progress({ done = done, total = total })
    return percent
end

--- 同步把页图打到 .part。只在 Job 子进程（或测试）里跑：不改最终路径、不删源图。
---@param paths string[]
---@param archive_path string
---@param screen_w integer
---@param screen_h integer
---@param progress fun(value: any)|nil
---@return { ok: boolean, pages: integer, error: string|nil }
function Cbz.packBuild(paths, archive_path, screen_w, screen_h, progress)
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    local dest_dir = archive_path:gsub("%.cb[zt]$", "") .. ".fit"
    ---@type string[]
    local temps = {}
    local function fail(err)
        writer:close()
        os.remove(tmp)
        for _idx, path in ipairs(temps) do os.remove(path) end
        removeDir(dest_dir)
        return { ok = false, pages = 0, error = err }
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        return fail(writer.err or _("无法创建漫画文件"))
    end
    local page_index, last_percent = 1, nil
    for src_index, src in ipairs(paths) do
        local pages, err = Fit.materialize(src, dest_dir, page_index, screen_w, screen_h)
        if not pages then
            return fail(err or _("无法读取漫画图片"))
        end
        page_index = page_index + #pages
        for _idx, page in ipairs(pages) do
            if page.temp then temps[#temps + 1] = page.path end
            local ok, add_err = addFile(writer, page.path, page.name)
            if not ok then return fail(add_err) end
            if page.temp then os.remove(page.path) end
        end
        last_percent = report(progress, src_index, #paths, last_percent)
        collectgarbage("collect")
    end
    writer:close()
    removeDir(dest_dir)
    return { ok = true, pages = page_index - 1 }
end

--- 把页图打成 CBZ；每张源图先缩小/切片，切片按序成为独立页。
---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
function Cbz.build(paths, archive_path, state, cb)
    state = state or { cancelled = false }
    if state.cancelled then return end
    local screen_w, screen_h = Fit.screen()
    local Job = require("workers.job")
    local settled = false
    local function finished()
        settled = true
        state.job = nil
        state.writer = nil
        Cbz.clearWork(archive_path)
    end
    local job = Job.run(function(progress)
        return Cbz.packBuild(paths, archive_path, screen_w, screen_h, progress)
    end, {
        name = "cbz.build",
        kind = "heavy",
        on_progress = state.on_progress,
        on_done = function(result)
            settled = true
            if state.cancelled then
                finished()
                return
            end
            if type(result) ~= "table" or not result.ok then
                finished()
                cb(nil, (type(result) == "table" and result.error) or _("无法保存漫画文件"))
                return
            end
            local ok, err = os.rename(archive_path .. ".part", archive_path)
            if not ok then
                finished()
                cb(nil, err or _("无法保存漫画文件"))
                return
            end
            for _idx, image_path in ipairs(paths) do os.remove(image_path) end
            finished()
            cb(archive_path)
        end,
        on_failed = function(err)
            finished()
            if not state.cancelled then cb(nil, err) end
        end,
        on_cancelled = function()
            finished()
        end,
    })
    if not settled then attachJob(state, archive_path, job) end
end

return Cbz
