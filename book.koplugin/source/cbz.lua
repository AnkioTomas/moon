--[[--
把一章的页图打成 CBZ（zip，store 模式）。漫画源共用，打包成功后删掉散页图。

@module koplugin.book.source.cbz
--]]

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

---@param paths string[]
---@param archive_path string
---@param state table
---@param cb fun(path: string|nil, err: string|nil)
function Cbz.build(paths, archive_path, state, cb)
    local tmp = archive_path .. ".part"
    os.remove(tmp)
    local writer = require("ffi/archiver").Writer:new()
    --- 打包中途失败：关 writer、删半截文件后回调错误。
    local function fail(err)
        writer:close()
        state.writer = nil
        os.remove(tmp)
        cb(nil, err)
    end
    if not writer:open(tmp, "zip") or not writer:setZipCompression("store") then
        fail(writer.err or _("无法创建漫画文件"))
        return
    end
    state.writer = writer
    local index = 1
    local function nextFile()
        if state.cancelled then return end
        local path = paths[index]
        if not path then
            writer:close()
            state.writer = nil
            local ok, err = os.rename(tmp, archive_path)
            if not ok then
                os.remove(tmp)
                cb(nil, err or _("无法保存漫画文件"))
                return
            end
            for _idx, image_path in ipairs(paths) do os.remove(image_path) end
            cb(archive_path)
            return
        end
        local file, err = io.open(path, "rb")
        if not file then
            fail(err or _("无法读取漫画图片"))
            return
        end
        local data = file:read("*a")
        file:close()
        local name = path:match("([^/\\]+)$") or tostring(index)
        if not writer:addFileFromMemory(name, data) then
            fail(writer.err or _("无法写入漫画文件"))
            return
        end
        index = index + 1
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz write", nextFile))
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("cbz write", nextFile))
end

return Cbz
