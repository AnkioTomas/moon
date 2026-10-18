--[[--
local_scan 表：本地书库扫盘索引，路径 → 文件指纹（大小:修改时间）/ 内容 md5 / 是否试过补封面。

只是加速缓存：行丢了就重算 md5、重试一次封面，扫盘结果不变；不关联 books，不发也不订阅事件。
只在主进程读写（扫盘子进程不碰库）：扫盘前 all() 交给子进程，结束后 save() 按本轮结果收敛。

@module koplugin.book.source.local.scan_db
--]]

local DB = require("utils.db")

local ScanDB = {}

DB.schema("local_scan", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS local_scan (
  path TEXT PRIMARY KEY, fp TEXT NOT NULL, md5 TEXT, cover INTEGER NOT NULL DEFAULT 0
);
]]) ~= nil
end)

---@alias LocalScanIndex table<string, { fp: string, md5: string|nil, cover: boolean }>

---@return LocalScanIndex
function ScanDB.all()
    local result, nrows = DB.query("SELECT path, fp, md5, cover FROM local_scan;")
    local out = {}
    for i = 1, nrows do
        out[result[1][i]] = { fp = result[2][i], md5 = result[3][i], cover = tonumber(result[4][i]) == 1 }
    end
    return out
end

--- 按本轮扫盘结果收敛：有变化的行写入，盘上没了的删掉；没变化不写。
---@param old LocalScanIndex 扫盘前 all() 的结果
---@param files { path: string, fp: string, md5: string|nil, cover_tried: boolean|nil }[]
---@param partial boolean|nil 扫盘中途的一批：只写有变化的行并同步进 old，不删盘上没了的（后面的批次还没到）
---@return boolean
function ScanDB.save(old, files, partial)
    return DB.transaction(function()
        local seen = {}
        for _idx, f in ipairs(files) do
            seen[f.path] = true
            local was, cover = old[f.path], f.cover_tried == true
            if (not was or was.fp ~= f.fp or was.md5 ~= f.md5 or was.cover ~= cover) and not DB.exec(
                [[INSERT INTO local_scan (path, fp, md5, cover) VALUES (?,?,?,?)
                  ON CONFLICT(path) DO UPDATE SET fp=excluded.fp, md5=excluded.md5, cover=excluded.cover;]],
                f.path, f.fp, f.md5, cover and 1 or 0
            ) then
                return nil
            end
            old[f.path] = { fp = f.fp, md5 = f.md5, cover = cover }
        end
        if partial then return true end
        for path in pairs(old) do
            if not seen[path] and not DB.exec("DELETE FROM local_scan WHERE path=?;", path) then return nil end
        end
        return true
    end) ~= nil
end

--- 清空「试过补封面」标记：封面缓存（.moon/cache）被整体清掉后调用，下一轮扫盘对缺封面的书重新提取。
--- 不动 fp / md5，扫盘仍走指纹快路径，不会整库重算。
---@return boolean
function ScanDB.resetCovers()
    return DB.exec("UPDATE local_scan SET cover=0 WHERE cover<>0;") ~= nil
end

return ScanDB
