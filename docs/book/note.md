# book.note — 注解快照

代码：[`book/note.lua`](../../book.koplugin/book/note.lua)。表：[`notes`](../db/notes.md)。

## 设计

按书或按章保存 KOReader **注解完整快照**（JSON `payload`），不是增量 patch。上传只读 notes 表，避免异步发出已改内存表。

| `chapter_idx` | 含义 |
|---|---|
| `0` | 整本桶 |
| 正整数 | 该章分片 |

```text
划线变更 → Note.save → 落库 sync_status=0 → 有网 dirty push
开书     → Note.applyLocal（首绘前同步）→ Note.pull
切章     → 必须再 applyLocal（注解按章分片）
关书     → 只推脏；完整 pull 留给下次开书
```

Merge 策略：远端「空列表」与「字段缺失」在 wire 上无法区分。  
**宁可漏掉云端删除，也不清本地划线。** 仅当快照带 `authoritative=true`（或源 `legacyAuthoritativeAnnotations`）时，才把「远端未返回的已同步分片」视为空桶。

无进度那种 ConfirmBox——靠 dirty 位 + merge 收敛。

`markSynced` 必须同语句回填 payload 并清脏（见 db 文档），避免推送成功后本地读到旧快照。

---

## 用法

```lua
local Note = require("book.note")

-- Session.onReaderReady / 切章后
Note.applyLocal(ui, identity)

-- 有网时开书拉取
Note.pull(ui, identity)

-- onAnnotationsModified
Note.save(ui, identity, function(ok)
    if not ok then return end
    identity.source:syncNotesAsync({
        identity = identity,
        dirty_only = true,
    }, function() end)
end)

-- 编排
Note.syncAsync(source, { identity = identity, dirty_only = true }, cb)
```

payload 形态（normalize）：

```lua
-- 普通：JSON 数组
-- 权威完整快照：{ items = {…}, authoritative = true }
```

### 注意

- 切章后若晚一个 tick 才 applyLocal，云端划线要等下次刷新才出现——所以 bootstrap 里同步调用。
- 编排层对笔记域永远 `dirty_only`。
- 不要把 `ui.annotation.annotations` 直接当上传源；以落库行为准。
