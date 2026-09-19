# 设计文档

`book.koplugin/` 的实现契约：每个模块写清**怎么设计的、怎么用**。表结构见 [`db/`](db/README.md)。

## 模块索引

| 模块 | 内容 |
|---|---|
| [`plugin/`](plugin/README.md) | KOReader 接线、Host、源事件 |
| [`db/`](db/README.md) | `book.sqlite3` 各表 |
| [`book/`](book/README.md) | 身份 / 打开 / catalog / 进度 / 笔记 / 统计 / 同步 |
| [`source/`](source/README.md) | 注册表、基类、按章、各源 |
| [`ui/`](ui/README.md) | Lifecycle、桌面、阅读会话 |
| [`http/`](http/README.md) | Turbo 请求 |
| [`workers/`](workers/README.md) | Job |
| [`remote/`](remote/README.md) | 远程管理 |
| [`lockscreen/`](lockscreen/README.md) | 组合锁屏 |
| [`ime/`](ime/README.md) | 中文输入 |
| [`online/`](online/README.md) | ankio.net |
| [`zlib/`](zlib/README.md) | Z-Library 书城（非源） |
| [`ai/`](ai/README.md) | OpenAI 兼容门面 |
| [`xray/`](xray/README.md) | 阅读实体（仅本地） |
| [`dictionary/`](dictionary/README.md) | StarDict 接管 |
| [`translate/`](translate/README.md) | Edge 翻译 |
| [`baike/`](baike/README.md) | 百度百科 |
| [`scrape/`](scrape/README.md) | 元数据刮削 |
| [`convert/`](convert/README.md) | TXT/HTML/MOBI → EPUB |
| [`update/`](update/README.md) | 插件自更新 |
| [`patch/`](patch/README.md) | KOReader 核心补丁 |
| [`utils/`](utils/README.md) | 路径、设置、文字 |

依赖单向：`main → ui/book → source → http`；fork 子进程不碰库（`instant` 除外）。
