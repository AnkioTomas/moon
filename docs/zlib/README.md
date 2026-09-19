# zlib/ — Z-Library 书城

路径：[`book.koplugin/zlib/`](../../book.koplugin/zlib/)。全局书城门面，**不是** BookSource；下载后导入**当前数据源**书库。

## 设计

- client：镜像种子、手动跟随重定向、bot 挑战、故障转移（行为移植自 zlibrary.koplugin）。
- 传输必须走本插件 `http.request`，禁止同步 `socket.http`。
- 搜索语言由 KOReader 界面语言映射（含 `zh_TW` 等 override）。

## 用法

```lua
local Zlib = require("zlib")
Zlib.listStoreAsync(opts, cb)      -- 有关键词或语言 → search，否则 popular
Zlib.getDetailAsync(stable_id, cb)
Zlib.downloadAsync(item, cb)       -- 完成后按当前源 import
```

桌面「书城」Tab 挂这里；不要给 zlib 伪造 Source 能力表。
