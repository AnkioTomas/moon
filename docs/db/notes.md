# notes

## 职责

按书或按章保存 KOReader **注解完整快照**（JSON `payload`），并带 `sync_status` 与远端划线/书签收敛。

## 非职责

- 不存进度、统计、书架成员
- 不存 KOReader sidecar 以外的第二套划线模型（payload 即原生 annotations 序列化）

## 主键 / 索引

- **PK**：`(source_id, stable_id, chapter_idx)`
- 无额外索引（按身份点查 / `sync_status=0` 扫描）

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `source_id` / `stable_id` | 书身份 | upsert* | get / unsynced | |
| `chapter_idx` | `0` = 整本文件；正数 = 章文件 | upsert* | 分片拉取/合并 | DEFAULT 0 |
| `payload` | JSON 注解快照 | upsert* / markSynced 可回填 | 开书 apply / 同步 | NOT NULL |
| `updated_at` | 修订号 | upsert | markSynced 乐观锁 | |
| `sync_status` | 0 待上传 / 1 已同步 | upsert 可指定；远端写入为 1 | unsynced | |

## 数据流

| API | 行为 |
|---|---|
| `NoteDB.upsert` | 覆盖快照；`synced` 参数决定 status |
| `NoteDB.upsertRemote` | 写入已同步快照；**仅当现有行 `sync_status=1` 时才 UPDATE**（脏行保留） |
| `NoteDB.markSynced` | push 成功：同一语句写 `sync_status=1` 并可回填带远端 id 的 payload；WHERE 含 `updated_at` |
| `NoteDB.unsynced` | 脏队列 |

领域层：`book.note`（save / pull / syncAsync）。有网即 `dirty_only` 推（划线改动 / 关书 / 脏重试）；完整 pull 仅开书 `Note.pull`。`Sync.runAsync` 对笔记域强制 `dirty_only`。

## 同步语义

与进度同构：脏先推；远端不覆盖本地脏快照。  
`markSynced` 必须把 payload 回填与清脏放在**同一语句**，避免「先盖旧 payload 再 mark」吃掉上传期间新划线。

`retryDirtyAsync` 会扫描本表。

## 与其他表关系

- 身份对齐 [`books`](books.md)
- 章文件打开时按 `chapter_idx` 分片；与 [`chapters`](chapters.md) 的章号一致，但不经 chapters 表读写注解

## 不变量 / 地雷

1. `chapter_idx=0` 与「整本 EPUB」会话对应；按章源用正数分片。  
2. 合并失败策略在领域层（宁可丢云端也不删本地划线），本表只保证脏保护。  
3. 无独立 ConfirmBox；冲突靠 dirty + merge，不靠用户弹窗。

## 代码入口

- [`book.koplugin/db/note.lua`](../../book.koplugin/db/note.lua)
- [`book.koplugin/book/note.lua`](../../book.koplugin/book/note.lua)
- 源侧注解协议：如 `source/wechat/notes.lua`、`source/moon` annotations
