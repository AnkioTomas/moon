--[[--
chapter_summaries 表：AI 生成的章节摘要，供前情提要、X-Ray、划词解释、读后总结共用。

chapter_idx 是阅读会话的目录章序号（`reader.session` 的 `chapterIndex`，从 1 开始），摘要在 summary 列。
chapter_idx = 0 是整本书一行，只用 extra 列存读书报告（单文件、按章下载的书都一样）。
纯本地派生数据，无云同步，丢了可以重新生成。

不变量：
  - 防剧透靠查询边界：读前文只取 `1 ≤ chapter_idx ≤ 当前章`，调用方不另写过滤。
书改名 / 收编时由 books_db 调 moveIdentity 迁身份，撕墓碑时调 removeIdentity。

@module koplugin.book.ai.summary_db
--]]

local DB = require("utils.db")

local SummaryDB = {}

local BOOK_ROW = 0

DB.schema("chapter_summaries", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS chapter_summaries (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, chapter_idx INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '', extra TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);
]]) ~= nil
end)

--- 书改名 / 收编时由 books_db 调用。
function SummaryDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return DB.moveIdentity("chapter_summaries", source_id, old_stable_id, new_stable_id, merge)
end

--- 书被删（墓碑撕掉）时由 books_db 调用。
function SummaryDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("chapter_summaries", source_id, stable_id)
end

--- 写入（覆盖）一章摘要。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer 从 1 开始
---@param title string
---@param summary string
---@return boolean
function SummaryDB.put(source_id, stable_id, chapter_idx, title, summary)
    return DB.exec(
        [[INSERT INTO chapter_summaries (source_id, stable_id, chapter_idx, title, summary, updated_at)
          VALUES (?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, chapter_idx) DO UPDATE SET
            title=excluded.title, summary=excluded.summary, updated_at=excluded.updated_at;]],
        source_id, stable_id, chapter_idx, title, summary, os.time()) ~= nil
end

---@class BookChapterSummary
---@field chapter_idx integer
---@field title string
---@field summary string
---@field updated_at integer

--- 取一章摘要；没有返回 nil。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@return BookChapterSummary|nil
function SummaryDB.get(source_id, stable_id, chapter_idx)
    local title, summary, updated_at = DB.rowexec(
        [[SELECT title, summary, updated_at FROM chapter_summaries
          WHERE source_id=? AND stable_id=? AND chapter_idx=?;]],
        source_id, stable_id, chapter_idx)
    if not summary then return nil end
    return { chapter_idx = chapter_idx, title = title, summary = summary, updated_at = tonumber(updated_at) }
end

--- 截至 max_idx（含）的最后 limit 章摘要，按章序升序。
---@param source_id string
---@param stable_id string
---@param max_idx integer
---@param limit integer
---@return BookChapterSummary[]
function SummaryDB.upTo(source_id, stable_id, max_idx, limit)
    local result, nrows = DB.query(
        [[SELECT chapter_idx, title, summary, updated_at FROM chapter_summaries
          WHERE source_id=? AND stable_id=? AND chapter_idx BETWEEN 1 AND ?
          ORDER BY chapter_idx DESC LIMIT ?;]],
        source_id, stable_id, max_idx, limit)
    local out = {}
    for i = nrows, 1, -1 do
        out[#out + 1] = {
            chapter_idx = tonumber(result[1][i]),
            title = result[2][i],
            summary = result[3][i],
            updated_at = tonumber(result[4][i]),
        }
    end
    return out
end

--- 写入整本书的读书报告。
---@param source_id string
---@param stable_id string
---@param text string
---@return boolean
function SummaryDB.putReport(source_id, stable_id, text)
    return DB.exec(
        [[INSERT INTO chapter_summaries (source_id, stable_id, chapter_idx, extra, updated_at)
          VALUES (?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, chapter_idx) DO UPDATE SET
            extra=excluded.extra, updated_at=excluded.updated_at;]],
        source_id, stable_id, BOOK_ROW, text, os.time()) ~= nil
end

--- 读整本书的读书报告；没有返回 nil。
---@param source_id string
---@param stable_id string
---@return string|nil
function SummaryDB.report(source_id, stable_id)
    local extra = DB.rowexec(
        [[SELECT extra FROM chapter_summaries WHERE source_id=? AND stable_id=? AND chapter_idx=?;]],
        source_id, stable_id, BOOK_ROW)
    return extra ~= nil and extra ~= "" and extra or nil
end

return SummaryDB
