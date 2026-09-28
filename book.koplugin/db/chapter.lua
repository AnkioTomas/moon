--[[--
chapters 表：章节文件路径 → 所属书籍身份。

章节不进入 books 表；身份解析的唯一入口是 path 精确匹配。
无云同步。updated_at 随 upsert 写入，查询不读（历史列，不扩语义）。

@module koplugin.book.db.chapter
--]]

local Base = require("db.base")

local ChapterDB = {}

--- 创建 chapters 表及按书籍身份查询的索引。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function ChapterDB.ensureSchema()
    return Base.exec([[
CREATE TABLE IF NOT EXISTS chapters (
  path TEXT PRIMARY KEY, source_id TEXT NOT NULL, stable_id TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chapters_book ON chapters(source_id, stable_id);
]]) ~= nil
end

--- 按章节文件路径取身份
---@param path string
---@return { source_id: string, stable_id: string, chapter_idx: integer }|nil
function ChapterDB.get(path)
    local source_id, stable_id, chapter_idx = Base.rowexec(
        [[SELECT source_id, stable_id, chapter_idx FROM chapters WHERE path=? LIMIT 1;]],
        path
    )
    if not source_id then
        return nil
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = tonumber(chapter_idx),
    }
end

--- 按书统计已登记的章节文件数。
---@param source_id string
---@param stable_id string
---@return integer
function ChapterDB.countByBook(source_id, stable_id)
    return tonumber(Base.rowexec(
        [[SELECT COUNT(*) FROM chapters WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    )) or 0
end

--- 某源（或多源）登记过的全部章节文件路径。
---@param source_id string|string[]
---@return string[]
function ChapterDB.pathsBySource(source_id)
    local where, args = Base.sourceClause("source_id", source_id)
    local result, nrows = Base.query("SELECT path FROM chapters WHERE " .. where .. ";", unpack(args))
    local out = {}
    for i = 1, nrows do out[i] = result[1][i] end
    return out
end

--- 登记章节文件路径 → 书籍身份
---@param row { path: string, source_id: string, stable_id: string, chapter_idx: integer }
---@return boolean
function ChapterDB.upsert(row)
    return Base.exec(
        [[INSERT INTO chapters (path, source_id, stable_id, chapter_idx, updated_at)
          VALUES (?,?,?,?,?)
          ON CONFLICT(path) DO UPDATE SET
            source_id=excluded.source_id,
            stable_id=excluded.stable_id,
            chapter_idx=excluded.chapter_idx,
            updated_at=excluded.updated_at;]],
        row.path,
        row.source_id,
        row.stable_id,
        tonumber(row.chapter_idx),
        os.time()
    ) ~= nil
end

--- 删除某目录下全部章节登记（缓存目录被清理）
---@param dir string
---@return boolean
function ChapterDB.deleteUnder(dir)
    -- 空 dir 会拼成 LIKE '/%'，删光所有绝对路径登记；必须挡住
    if dir == "" then
        return false
    end
    return Base.exec(
        [[DELETE FROM chapters WHERE path LIKE ? ESCAPE '\';]],
        dir:gsub("([%%_\\])", "\\%1") .. "/%"
    ) ~= nil
end

--- 删除指向某文件的章节登记
---@param path string
---@return boolean
function ChapterDB.delete(path)
    return Base.exec([[DELETE FROM chapters WHERE path=?;]], path) ~= nil
end

--- 一个事务删除多条章节登记（整本缓存被手动删掉时可达上千条，逐条自动提交会卡住界面）。
---@param paths string[]
---@return boolean
function ChapterDB.deleteMany(paths)
    if not Base.exec("BEGIN IMMEDIATE;") then return false end
    for _, path in ipairs(paths) do
        if not ChapterDB.delete(path) then
            Base.exec("ROLLBACK;")
            return false
        end
    end
    if Base.exec("COMMIT;") then return true end
    Base.exec("ROLLBACK;")
    return false
end

return ChapterDB
