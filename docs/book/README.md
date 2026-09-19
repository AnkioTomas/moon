# book/ — 书籍领域

路径：[`book.koplugin/book/`](../../book.koplugin/book/)。编排身份、打开、目录查询、进度、笔记、统计和同步。表结构见 [`../db/`](../db/README.md)。

## 设计总览

```text
UI / Session
    ↓
book.open / progress / note / stats / catalog / sync
    ↓
source（属主实例） + db（SQLite）
```

- 跨源身份 = `(source_id, stable_id)`；`chapter_idx` 只表示章位置，不进主键。
- **属主源跟身份走**：打开、同步、事件一律用 `identity.source`，禁止 `registry.current()` 操作旧书。
- UI 只读本地库；远端结果必须先经源 `sync*` 写回再展示。
- 同步契约：本地优先 push，再 pull。进度/笔记 pull **仅开书**；关书与脏重试只推。

## 文档索引

| 文档 | 讲什么 |
|---|---|
| [`store`](store.md) | 路径→身份、`touch` 登记、书架 reconcile |
| [`open`](open.md) | 按属主源打开物理文档 |
| [`catalog`](catalog.md) | 图书馆 / 最近阅读 / 筛选 / 洞察（只读库） |
| [`progress`](progress.md) | 进度落盘、开书冲突、推送 |
| [`note`](note.md) | 注解快照、分片、merge |
| [`stats`](stats.md) | 阅读计时与上报 |
| [`sync`](sync.md) | 四域编排与脏重试 |

同目录还有 `reader_prefs`（全书排版 sidecar）、`highlights`、`reflow`、`cache`——接口见各文件头注释。
