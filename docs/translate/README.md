# translate/ — Edge 翻译与整书双语对照

路径：[`book.koplugin/features/translate/`](../../book.koplugin/features/translate/)。

两件事：把 Edge 翻译接入 KOReader 划词翻译 UI（关闭后完整回退原生 Translator）；阅读快捷面板「双语对照」整书翻译。

## 设计

| 文件 | 作用 |
|---|---|
| `edge.lua` | **只**负责 HTTP 传输与响应解析；单条 `translateAsync`，批量 `translateListAsync` |
| `init.lua` | 开关、联网恢复、注入 Translator |
| `popup.lua` | 翻译弹窗（切语言、存笔记等） |
| `languages.lua` | 语言列表 |
| `panel.lua` | 阅读快捷动作 `bilingual` |
| `bilingual.lua` | 整书双语：入后台任务、分批并发翻译、生成双语版、原文 / 双语切换 |
| `markup.lua` | 纯 Lua：找叶子块、取原文、在块尾插入译文（子进程里跑） |

划词翻译离线时经 `NetworkMgr:willRerunWhenConnected` 排队（不用会走同步 DNS 的 `willRerunWhenOnline`），联网回调原样透传参数重跑。有剪贴板的设备会先把原文写入剪贴板。开关 `features.translate.edge_translation_enabled`，默认开启。

## 双语对照

- 引擎：Edge（一次请求 40 段 / 4000 字符，3 并发）或 AI（20 段 / 2000 字符，2 并发，JSON 数组进出，条数对不上整批重试）。目标语言用 KOReader 翻译设置里的目标语言。
- 任务：`workers/tasks` 的 `cache` 类，`key = bilingual\0<source_id>\0<stable_id>`，可续跑（断网 / 休眠放回等待），翻译失败退避重试。
- 产物在书的工作目录 `bilingual/`：`<engine>-<lang>.jsonl` 译文缓存（一行一个 `[原文, 译文]`，只追加，中断后跳过已译段落）、`meta.json`（`{ origin, file }`）、`book.epub|fb2|html`。清缓存 / 删书时随工作目录一起删掉。
- 格式：EPUB 逐个改写包内 XHTML，样式和图片保留；其余 CREngine 格式（TXT、FB2、MOBI、AZW3、DOCX…）导出 DOM，按根元素写成 `.fb2` / `.html`，图片不保留。
- 位置：译文插在原段落元素内部末尾（`<br/><span class="moon-tr" style="display:block">…</span>`，自成段落；关掉内嵌样式时退回换行），不新增兄弟元素，原文 xpointer 在两版通用。切换时把当前位置、排版和 DOM 版本写进目标文件 sidecar；从双语版切回时，落在译文里的位置退到所在段落。
- 身份：切换前 `Store.touch` 把 books.path 指向目标文件，开书按路径解析回同一本书，进度、笔记、统计都记在这本书上。按章阅读的章节文件不支持。
