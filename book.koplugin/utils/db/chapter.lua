--[[--
chapters 表：章节文件路径 → 所属书籍身份。

章节不进入 books 表；身份解析的唯一入口是 path 精确匹配。

@module koplugin.book.utils.db.chapter
--]]

local Base = require("utils.db.base")

local ChapterDB = {}

--- 按章节文件路径取身份
---@param path string
---@return { source_id: string, stable_id: string, chapter_idx: integer }|nil
function ChapterDB.get(path)
    Base.ensure()
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

--- 登记章节文件路径 → 书籍身份
---@param row { path: string, source_id: string, stable_id: string, chapter_idx: integer }
---@return boolean
function ChapterDB.upsert(row)
    Base.ensure()
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
    Base.ensure()
    return Base.exec(
        [[DELETE FROM chapters WHERE path LIKE ? ESCAPE '\';]],
        dir:gsub("([%%_\\])", "\\%1") .. "/%"
    ) ~= nil
end

--- 删除指向某文件的章节登记
---@param path string
---@return boolean
function ChapterDB.delete(path)
    Base.ensure()
    return Base.exec([[DELETE FROM chapters WHERE path=?;]], path) ~= nil
end

--- 全部章节登记（清缓存对账）
---@return { path: string, source_id: string, stable_id: string, chapter_idx: integer }[]
function ChapterDB.all()
    Base.ensure()
    local result, nrows = Base.query([[SELECT path, source_id, stable_id, chapter_idx FROM chapters;]])
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = {
                path = result[1][i],
                source_id = result[2][i],
                stable_id = result[3][i],
                chapter_idx = tonumber(result[4][i]),
            }
        end
    end
    return out
end

--- 清空全部章节登记（清缓存）
---@return boolean
function ChapterDB.clear()
    Base.ensure()
    return Base.exec([[DELETE FROM chapters;]]) ~= nil
end

return ChapterDB
