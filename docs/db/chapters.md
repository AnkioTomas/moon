# chapters

## 职责

把**章节物理文件 path** 精确映射到 `(source_id, stable_id, chapter_idx)`，供打开章文件时解析身份。

## 非职责

- 不存整本文件 path（整本在 [`books.path`](books.md)）
- 不存章节正文、目录 TOC、进度
- 不参与云同步

## 主键 / 索引

- **PK**：`path`
- `idx_chapters_book (source_id, stable_id)` — 按书清理/列举

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `path` | 章节文件绝对路径 | `ChapterDB.upsert` | `get` / 身份解析 | 主键 |
| `source_id` / `stable_id` | 属主书身份 | upsert | get / `all` | |
| `chapter_idx` | 章序号（从 1） | upsert | get | |
| `updated_at` | 登记时间 | upsert 写 `os.time()` | **查询不读** | 历史列，不扩语义 |

## 数据流

| 场景 | 路径 |
|---|---|
| 按章打开落盘 | `Store.touch`（含 `chapter_idx`）→ 同事务 `ChapterDB.upsert` |
| 开书身份 | `Store.ensureIdentity` → `ChapterDB.get(path)` 优先 |
| 清缓存目录 | `ChapterDB.deleteUnder(dir)`（空 dir 必须拒绝，防 `LIKE '/%'` 删光） |
| 删单文件登记 | `ChapterDB.delete(path)` |

## 同步语义

仅本地。无 `sync_status`。

## 与其他表关系

- 与 [`books`](books.md) 同身份；章会话 TOC 在 `books.toc`，不在本表。
- 进度章号在 [`pending_progress.chapter_idx`](pending_progress.md)，不依赖本表。

## 不变量 / 地雷

1. 身份解析：**先** `chapters.path`，**再** `books.path`。  
2. `deleteUnder("")` 必须失败，禁止误删全库路径。  
3. 章节**不得**写入 `books` 冒充整本行来解析章文件。

## 代码入口

- [`book.koplugin/db/chapter.lua`](../../book.koplugin/db/chapter.lua)
- [`book.koplugin/book/store.lua`](../../book.koplugin/book/store.lua)（`touch` / `ensureIdentity`）
- 按章公共落盘：[`book.koplugin/source/chapter.lua`](../../book.koplugin/source/chapter.lua)
