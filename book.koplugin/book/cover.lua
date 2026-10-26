--[[--
书籍封面缓存：从已打开的文档提取封面，落到 `Paths.coverPath(stable_id, source_id)`。

云端没有封面的书，下载到本地后靠它兜底；书架、详情、锁屏都认这个文件。
零 UI 依赖（local 扫盘在子进程里也调它）。

@module koplugin.book.book.cover
--]]

local lfs = require("libs/libkoreader-lfs")

local Cover = {}

local MAX_SIDE = 600

local MOBI_EXT = { mobi = true, prc = true, azw = true }

--- MOBI 引擎没给封面时按 EXTH 201 自己取（crengine 只认 JFIF 开头的 JPEG，见 utils.mobi.cover）。
---@param doc table
---@return table|nil bb
function Cover.mobiFallback(doc)
    local file = (type(doc) == "table" and doc.file) --[[@as string|nil]]
    local ext = type(file) == "string" and file:match("%.([^.]+)$")
    if not ext or not MOBI_EXT[ext:lower()] then return nil end
    ---@cast file string
    local data = require("utils.mobi").cover(file)
    if not data then return nil end
    local ok, bb = pcall(function() return require("ui/renderimage"):renderImageData(data, #data) end)
    return ok and bb or nil
end

--- 从已打开的文档提取封面写成 PNG；目标已存在或文档没有封面时什么都不做。
--- os.remove/os.rename 不抛异常，无需 pcall；取图与写盘是引擎调用，失败按“无封面”处理。
---@param doc table KOReader Document
---@param target string
---@return boolean|nil saved 目标文件已在或刚写成
function Cover.save(doc, target)
    if lfs.attributes(target, "mode") == "file" then
        return true
    end
    local ok_cover, bb = pcall(function()
        return doc:getCoverPageImage()
    end)
    if not (ok_cover and bb) then
        bb = Cover.mobiFallback(doc)
        if not bb then return end
    end
    -- 内嵌封面常是 1600×2400 彩图；按原尺寸落盘，之后每次显示都要全尺寸解码再缩。
    local scale = MAX_SIDE / math.max(bb:getWidth(), bb:getHeight())
    if scale < 1 then
        local ok_scaled, scaled = pcall(require("ffi/mupdf").scaleBlitBuffer, bb,
            math.floor(bb:getWidth() * scale), math.floor(bb:getHeight() * scale))
        if ok_scaled and scaled then
            bb:free()
            bb = scaled
        end
    end
    -- 清理缓存会删掉 cache/<source>/image 目录；任何源（含扫盘子进程）补封面前都要先建好。
    local dir = target:match("^(.*)/[^/]+$")
    if dir then require("utils.paths").ensureDir(dir) end
    local tmp = target .. ".part"
    local ok = pcall(function() bb:writePNG(tmp) end)
    pcall(function() bb:free() end)
    if not ok then
        os.remove(tmp)
        return
    end
    os.remove(target)
    if not os.rename(tmp, target) then
        os.remove(tmp)
        return
    end
    return true
end

return Cover
