--[[--
KOReader 按文档路径记的状态：.sdr 边车（进度、高亮、书签）、阅读历史、收藏、书目信息缓存。

书籍文件被删除或移动后跟着处理，规则对齐 KOReader 文件管理器。.sdr 的位置由
`document_metadata_folder`（doc / dir / hash）决定，且是去掉最后一个后缀再加 `.sdr`
（`a.pdf` → `a.sdr`），禁止自己拼 `path .. ".sdr"`。

@module koplugin.book.book.sidecar
--]]

local Sidecar = {}

--- 只清阅读数据，保留原书、排版设置、封面和收藏。旧格式与备份也不能留下可复活的笔记。
---@param path string
---@return boolean
function Sidecar.clearReading(path)
    local DocSettings = require("docsettings")
    local settings = DocSettings:open(path)
    if settings.candidates then
        for _idx, key in ipairs({
            "last_xpointer", "last_page", "percent_finished", "summary", "stats",
            "annotations", "annotations_rolling", "annotations_paging", "annotations_externally_modified",
            "highlight", "highlight_rolling", "highlight_paging",
            "bookmarks", "bookmarks_rolling", "bookmarks_paging",
            "book_note_linked", "book_note_orphans", "book_last_derived",
        }) do
            settings:delSetting(key)
        end
        local dir = settings:flush(nil, true)
        if not dir then
            require("utils.log").warn("book reading cleanup: sidecar write failed", path)
            return false
        end
        local saved = dir .. "/" .. settings.sidecar_filename
        local old_files = { [saved .. ".old"] = true }
        for _idx, candidate in ipairs(settings.candidates) do
            if candidate.path ~= saved then old_files[candidate.path] = true end
        end
        for old in pairs(old_files) do
            if require("libs/libkoreader-lfs").attributes(old) and not os.remove(old) then
                require("utils.log").warn("book reading cleanup: old sidecar removal failed", old)
                return false
            end
        end
    end
    require("readhistory"):removeItemByPath(path)
    require("ui/widget/booklist").resetBookInfoCache(path)
    return true
end

--- 书籍文件已删除：清 .sdr、阅读历史、收藏与书目信息缓存。文件已不存在也照常清。
---@param path string
function Sidecar.remove(path)
    require("ui/widget/booklist").resetBookInfoCache(path)
    require("docsettings").updateLocation(path)
    require("readhistory"):fileDeleted(path)
    require("readcollection"):removeItem(path)
end

--- 书籍文件已移到 new_path：.sdr 跟过去，阅读历史与收藏改指新路径。
--- 只搬目录、不改写里面的元数据：换格式（排版替换）时新旧 .sdr 是同一个目录，原样不动，
--- 不能像 DocSettings.updateLocation 那样把 PDF 的页码与标注抄成 EPUB 的。
---@param old_path string
---@param new_path string
---@return boolean ok, string|nil err .sdr 搬不动时为 false，调用方据此回滚
function Sidecar.move(old_path, new_path)
    -- hash 位置按文件内容寻址，不随路径变。
    if G_reader_settings:readSetting("document_metadata_folder") ~= "hash" then
        local DocSettings = require("docsettings")
        local old_dir, new_dir = DocSettings:getSidecarDir(old_path), DocSettings:getSidecarDir(new_path)
        if old_dir ~= new_dir and require("libs/libkoreader-lfs").attributes(old_dir, "mode") == "directory" then
            require("util").makePath((new_dir:match("^(.*)/[^/]+$")))
            local ok, err = os.rename(old_dir, new_dir)
            if not ok then return false, err end
        end
    end
    require("readhistory"):updateItem(old_path, new_path)
    require("readcollection"):updateItem(old_path, new_path)
    return true
end

return Sidecar
