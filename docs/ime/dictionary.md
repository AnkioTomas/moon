# ime 词库

代码：[`ime/download.lua`](../../book.koplugin/ime/download.lua)、`ime/<method>/dictionary.lua`、`table_dictionary.lua`。

## 设计

| 方法 | 库文件 |
|---|---|
| 拼音 | `$DATA/.moon/dictionary.sqlite3` |
| 五笔 / 仓颉 / 注音 | `$DATA/.moon/dictionary-<method>.sqlite3` |

产物源在仓库 `assets/pinyin/`、`assets/ime/<method>/`（manifest + 分片）。  
下载：按**当前布局**拉独立 manifest/分片 → worker 子进程校验拼接 → 原子落位 → **主进程 reset 对应词库连接与负缓存**。

子进程只做 FS；禁止在子进程打开 sqlite 查询词库。

---

## 用法

```lua
local Download = require("ime.download")

-- method: "pinyin" | "wubi" | "cangjie" | "zhuyin"；已在下载时 cb(false, "already downloading")
Download.ensure(method, function(ok, err)
    -- 落位后 download 已调用 Registry.reset(method)，调用方无需再 reset
end, function(stage, done, total, idx, count) end)

Download.downloading()  -- 是否有下载在进行
```

查询走各方法的 `dictionary.lua`（由候选栏调用），业务代码不要直接拼 SQL 路径。

### 注意

- 换布局后用的是另一套库文件；下载也要按新布局。
- 落位后不 reset = 继续读旧 mmap/旧句柄，表现为「下完了没词」。
- 布局列表快照必须与 `G_reader_settings` 里的表脱钩（浅拷贝），否则后续改写会污染快照。
