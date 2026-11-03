--[[--
微信书架全量快照的分批导入。

/shelf/sync 全量回包过大时，设备端解码会爆内存：原文不解码直接落盘（`stash`），
由远程管理网页下载、在浏览器里解码，再把书切成小批回传（`ingest`），最后 `commit` 对账并存游标。
设备端从头到尾不持有整份 wire；无状态，批与批之间不留内存。

@module koplugin.book.source.wechat.shelf_import
--]]

local Paths = require("utils.paths")
local _ = require("gettext")

local SOURCE_ID = "wechat"

local ShelfImport = {}

--- 回包超过这个字节数就不在设备上解码（解码后内存是原文数倍）。
ShelfImport.LIMIT = 1024 * 1024

ShelfImport.TOO_LARGE = _("书架数据太大，设备无法直接处理。已开启远程管理，请扫码在浏览器点「开始导入」完成同步。")
ShelfImport.PAGE = "/wechat_import.html"

---@return string
function ShelfImport.path()
    return Paths.sourceCacheDir(SOURCE_ID) .. "/shelf_full.json"
end

--- 原文落盘，覆盖上一份。
---@param body string
---@return boolean ok
---@return string|nil err
function ShelfImport.stash(body)
    Paths.ensureDir(Paths.sourceCacheDir(SOURCE_ID))
    local path = ShelfImport.path()
    local file, err = io.open(path .. ".part", "wb")
    if not file then return false, tostring(err) end
    local ok, werr = file:write(body)
    file:close()
    if ok then ok, werr = os.rename(path .. ".part", path) end
    if not ok then
        os.remove(path .. ".part")
        return false, tostring(werr)
    end
    return true
end

--- 待导入文件的字节数；没有返回 nil。
---@return integer|nil
function ShelfImport.size()
    local file = io.open(ShelfImport.path(), "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

function ShelfImport.discard()
    os.remove(ShelfImport.path())
end

--- 一批书入库。batch 是缩小版书架 wire：books / bookProgress / archive / albums，
--- 只含这批书相关的进度与分组（浏览器切好），字段口径与 Mapper.shelfList 一致。
---@param batch table
---@return string[]|nil ids 入库的 stable_id
---@return string|nil err
function ShelfImport.ingest(batch)
    local rows = require("source.wechat.mapper").shelfList(batch).data
    local BookDB = require("book.books_db")
    local ids = {}
    for _idx, row in ipairs(rows) do
        row.source_id = SOURCE_ID
        row.deleted = 0
        ids[#ids + 1] = row.stable_id
    end
    if not BookDB.upsertRemoteMany(rows) then return nil, "failed to save books" end
    return ids
end

--- 收尾：快照外的在架行下架，存增量游标，删原文件。ids 是各批 ingest 返回的全部 stable_id。
---@param ids string[]
---@param synckey number|nil
---@return integer|nil hidden
---@return string|nil err
function ShelfImport.commit(ids, synckey)
    local hidden = require("book.books_db").hideMissing(SOURCE_ID, ids)
    if not hidden then return nil, "failed to reconcile books" end
    if synckey then
        local Eink = require("source.wechat.eink")
        local cfg = require("utils.settings").getSource(SOURCE_ID)
        Eink.save({ shelf_cursor = { vid = cfg.wr_vid, synckey = synckey } })
    end
    ShelfImport.discard()
    return hidden
end

return ShelfImport
