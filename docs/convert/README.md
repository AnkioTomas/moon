# convert/ — 转 EPUB

路径：[`book.koplugin/convert/`](../../book.koplugin/convert/)。

把 TXT / HTML / MOBI 转成 EPUB，供 local 源入库。重活走 Job，结果回主进程再 `Store`/`扫盘`。

## 设计

| 模块 | 输入 |
|---|---|
| `text2epub.lua` | 纯文本：抽书名/作者/章节 → 复用 html2epub 打包 |
| `html2epub.lua` / `html.lua` | HTML 章节与打包 |
| `mobi2epub.lua` | MOBI → EPUB |

`text2epub` 按中文章节标题等启发式切章；大文件按块处理，避免一次读爆内存。

## 用法

```lua
local Text2Epub = require("convert.text2epub")

local job = Text2Epub.build({
    dest = "/path/book.epub",
    source = "/path/book.txt",
    title = "书名",   -- 可省略
    author = "作者",  -- 可省略
}, function(ok, err) end)

job.cancel()

-- HTML / MOBI 同理
require("convert.html2epub").build({ … }, cb)
require("convert.mobi2epub").build({ … }, cb)
```

产出路径应落在 local 书库根内或随后显式登记，否则桌面扫盘看不到。
