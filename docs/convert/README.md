# convert/ — 转 EPUB

路径：[`book.koplugin/convert/`](../../book.koplugin/convert/)。

把纯文本转成 EPUB。重活（zip 写入）走 Job，结果只经 `cb(ok, err)` 回到主进程；本模块不写库也不扫盘，登记路径由调用方负责（如 `features/reflow/init.lua` 成功后交源 `replaceBookAsync`）。MOBI 文本提取只有重排用，在 `features/reflow/mobi.lua`。

## 设计

| 模块 | 输入 |
|---|---|
| `text2epub.lua` | 纯文本：`read` 读 UTF-8 文件；`parse` 抽书名/作者/章节（`chapterTitle` 亦供阅读期自动目录）；`build` 复用 html2epub 打包 |
| `html2epub.lua` | 章节 HTML body → XHTML + OPF/NCX 打包（不含图片等外部资源） |

`text2epub` 按中文章节标题等启发式切章；超长章节按块拆成多个 XHTML。

## 用法

```lua
local Text2Epub = require("convert.text2epub")

local text, err = Text2Epub.read("/path/book.txt")
local job = Text2Epub.build({
    dest = "/path/book.epub",
    text = text,
    source = "/path/book.txt", -- 可省略，用于从文件名推断书名/作者
    title = "书名",   -- 可省略
    author = "作者",  -- 可省略
}, function(ok, err) end)

job.cancel()
```

产出路径应落在 local 书库根内或随后显式登记，否则桌面扫盘看不到。
