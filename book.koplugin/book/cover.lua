--[[--
书籍封面缓存：从已打开的文档提取封面，落到 `Paths.coverPath(stable_id, source_id)`。

云端没有封面的书，下载到本地后靠它兜底；书架、详情、锁屏都认这个文件。
零 UI 依赖（local 扫盘在子进程里也调它）。

@module koplugin.book.book.cover
--]]

local lfs = require("libs/libkoreader-lfs")

local Cover = {}

--- 从已打开的文档提取封面写成 PNG；目标已存在或文档没有封面时什么都不做。
--- os.remove/os.rename 不抛异常，无需 pcall；取图与写盘是引擎调用，失败按“无封面”处理。
---@param doc table KOReader Document
---@param target string
function Cover.save(doc, target)
    if lfs.attributes(target, "mode") == "file" then
        return
    end
    local ok_cover, bb = pcall(function()
        return doc:getCoverPageImage()
    end)
    if not (ok_cover and bb) then
        return
    end
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
    end
end

return Cover
