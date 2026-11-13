--[[--
chapter_summaries 表：AI 生成的章节摘要，供前情提要、X-Ray、划词解释、读后总结共用。

chapter_idx 是阅读会话的目录章序号（`reader.session` 的 `chapterIndex`，从 1 开始），摘要在 summary 列。
chapter_idx = 0 是整本书一行，只用 extra 列存读书报告（单文件、按章下载的书都一样）。
纯本地派生数据，无云同步，丢了可以重新生成。
chapter_summary_pending 保存已触发的请求快照；error 为空可自动恢复，失败须手动重试。
完成摘要与删除待办在同一事务内进行；待办跟随书籍身份迁移和清理，不存 AI 凭证。

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

DB.schema("chapter_summary_pending", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS chapter_summary_pending (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, chapter_idx INTEGER NOT NULL,
  title TEXT NOT NULL, messages TEXT NOT NULL, error TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);
]]) ~= nil
end)

--- 书改名 / 收编时由 books_db 调用。
function SummaryDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return DB.moveIdentity("chapter_summary_pending", source_id, old_stable_id, new_stable_id, merge)
        and DB.moveIdentity("chapter_summaries", source_id, old_stable_id, new_stable_id, merge)
end

--- 书被删（墓碑撕掉）时由 books_db 调用。
function SummaryDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("chapter_summary_pending", source_id, stable_id)
        and DB.removeIdentity("chapter_summaries", source_id, stable_id)
end

--- 退出登录：删掉这个源的全部章节摘要。
function SummaryDB.removeSource(source_id, stable_prefix, exclude)
    return DB.removeSource("chapter_summary_pending", source_id, stable_prefix, exclude)
        and DB.removeSource("chapter_summaries", source_id, stable_prefix, exclude)
end

---@class BookPendingSummary
---@field source_id string
---@field stable_id string
---@field chapter_idx integer
---@field title string
---@field messages string 已裁剪的请求 JSON
---@field error string

--- 首次触发时保存快照；重读不覆盖已有请求或失败状态。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param title string
---@param messages string
---@return boolean
function SummaryDB.putPending(source_id, stable_id, chapter_idx, title, messages)
    return DB.exec([[INSERT INTO chapter_summary_pending
        (source_id, stable_id, chapter_idx, title, messages, updated_at)
        VALUES (?,?,?,?,?,?) ON CONFLICT(source_id, stable_id, chapter_idx) DO NOTHING;]],
        source_id, stable_id, chapter_idx, title, messages, os.time()) ~= nil
end

---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@return BookPendingSummary|nil
function SummaryDB.getPending(source_id, stable_id, chapter_idx)
    local title, messages, err = DB.rowexec([[SELECT title, messages, error FROM chapter_summary_pending
        WHERE source_id=? AND stable_id=? AND chapter_idx=?;]], source_id, stable_id, chapter_idx)
    if not messages then return nil end
    return { source_id = source_id, stable_id = stable_id, chapter_idx = chapter_idx,
        title = title, messages = messages, error = err }
end

--- 只取待办元信息，跳过书库墓碑，不批量加载正文；每轮最多填一队列。
---@param source_id string|nil
---@param stable_id string|nil
---@return { source_id: string, stable_id: string, chapter_idx: integer }[]|nil
function SummaryDB.pending(source_id, stable_id)
    require("book.books_db")
    local where, args = { "p.error=''", "COALESCE(b.deleted,0)=0", "(s.summary IS NULL OR s.summary='')" }, {}
    if source_id then where[#where + 1] = "p.source_id=?"; args[#args + 1] = source_id end
    if stable_id then where[#where + 1] = "p.stable_id=?"; args[#args + 1] = stable_id end
    local result, count = DB.query([[SELECT p.source_id, p.stable_id, p.chapter_idx
        FROM chapter_summary_pending p LEFT JOIN books b
          ON b.source_id=p.source_id AND b.stable_id=p.stable_id
        LEFT JOIN chapter_summaries s
          ON s.source_id=p.source_id AND s.stable_id=p.stable_id AND s.chapter_idx=p.chapter_idx
        WHERE ]] .. table.concat(where, " AND ") .. [[
        ORDER BY p.updated_at, p.source_id, p.stable_id, p.chapter_idx LIMIT 64;]], unpack(args))
    if not result then return nil end
    local out = {}
    for i = 1, count do
        out[i] = { source_id = result[1][i], stable_id = result[2][i], chapter_idx = tonumber(result[3][i]) }
    end
    return out
end

---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@return boolean
function SummaryDB.removePending(source_id, stable_id, chapter_idx)
    return DB.exec([[DELETE FROM chapter_summary_pending
        WHERE source_id=? AND stable_id=? AND chapter_idx=?;]], source_id, stable_id, chapter_idx) ~= nil
end

---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param err string
---@return boolean
function SummaryDB.failPending(source_id, stable_id, chapter_idx, err)
    return DB.exec([[UPDATE chapter_summary_pending SET error=?
        WHERE source_id=? AND stable_id=? AND chapter_idx=?;]], err, source_id, stable_id, chapter_idx) ~= nil
end

---@param source_id string
---@param stable_id string
---@return boolean
function SummaryDB.retryPending(source_id, stable_id)
    return DB.exec([[UPDATE chapter_summary_pending SET error=''
        WHERE source_id=? AND stable_id=?;]], source_id, stable_id) ~= nil
end

--- 结果与待办一起提交，不能出现已保存摘要但待办还会被恢复的半状态。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param title string
---@param summary string
---@return boolean
function SummaryDB.finishPending(source_id, stable_id, chapter_idx, title, summary)
    return DB.transaction(function()
        return SummaryDB.put(source_id, stable_id, chapter_idx, title, summary)
            and SummaryDB.removePending(source_id, stable_id, chapter_idx)
    end) == true
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
