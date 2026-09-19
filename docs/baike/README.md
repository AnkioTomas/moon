# baike/ — 百度百科

路径：[`book.koplugin/baike/`](../../book.koplugin/baike/)。

把 KOReader Wikipedia 查询入口换成百度百科卡片。保留原事件名和按钮 id，已有手势/划词菜单显隐配置仍有效。  
**不**把百科硬包装成可切语言、可导 EPUB 的维基百科。

## 设计

- `init.lua`：开关、hook `ReaderWikipedia`、取消在飞查询
- `client.lua`：HTTP（走 `http.request`）
- 句柄挂在 Reader 实例上（`_book_baike_job`），不要模块级全局 job 串请求

默认开启：`reader.baike_enabled ~= false`。

## 用法

```lua
local Baike = require("baike")

Baike.isEnabled()
Baike.onCreate()   -- main 初始化
-- 关闭后完整回退原生 Wikipedia
```

查词仍走 KOReader 原入口；本模块只替换传输与结果展示。
