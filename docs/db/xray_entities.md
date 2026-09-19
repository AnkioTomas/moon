# xray_entities

## 职责

一书一组 **X-Ray 实体**（按 `kind` + `name`）的本地缓存，供阅读侧查询与展示。

## 非职责

- 不参与云同步（无 `sync_status`）
- 不存进度、注解、统计、全文正文
- 不替代章节 path 映射（见 [`chapters`](chapters.md)）

## 主键 / 索引

- **PK**：`(source_id, stable_id, kind, name)`
- `idx_xray_entities_book (source_id, stable_id, kind)` — 按书 / 按类列举

## 列契约

| 列 | 含义 | 谁写 | 谁读 | 备注 |
|---|---|---|---|---|
| `source_id` / `stable_id` | 属主书身份 | upsert / replace | list | |
| `kind` | 实体种类 | 同上 | list 过滤 | PK 一部分 |
| `name` | 实体名 | 同上 | UI / 匹配 | PK 一部分 |
| `aliases` | 别名串 | upsert | list → 拆成表 | 存库用 `、` 连接；空串默认 |
| `role` / `description` / `gender` / `occupation` | 展示字段 | upsert | UI | DEFAULT `''` |
| `updated_at` | 写入时间 | upsert（默认 `os.time()`） | list | |

## 数据流

| 场景 | 路径 |
|---|---|
| 单条写入 | `XrayDB.upsert`（ON CONFLICT 覆盖展示字段） |
| 整书替换 | `XrayDB.replace`（事务内删书下全部再批量 upsert） |
| 阅读查询 | `XrayDB.list(source_id, stable_id, kind?)` |

## 同步语义

仅本地。无脏队列；`retryDirtyAsync` 不碰本表。

## 与其他表关系

- 身份挂 [`books`](books.md) 的 `(source_id, stable_id)`
- 与章节表无 FK

## 不变量 / 地雷

1. 换源 / 换 `stable_id` 不自动迁移实体；旧行成孤儿直到 `replace`/按书清理。  
2. 别名编解码约定是中文顿号 `、`；业务层不要另造分隔符。  
3. 大部头用 `replace` 整书写，避免无事务逐条刷。

## 代码入口

- [`book.koplugin/db/xray.lua`](../../book.koplugin/db/xray.lua)
- 阅读 / 桌面 X-Ray UI 调用方（生成管线完成后 `replace`）
