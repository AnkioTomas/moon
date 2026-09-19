# translate/ — Edge 翻译

路径：[`book.koplugin/translate/`](../../book.koplugin/translate/)。

把 Edge 翻译接入 KOReader 翻译 UI。关闭后完整回退原生 Translator。

## 设计

| 文件 | 作用 |
|---|---|
| `edge.lua` | **只**负责 HTTP 传输与响应解析 |
| `init.lua` | 开关、联网恢复、注入 Translator |
| `popup.lua` | 翻译弹窗（切语言、存笔记等） |
| `languages.lua` | 语言列表 |

离线时经 `NetworkMgr:willRerunWhenOnline` 排队，联网回调必须原样透传参数重跑。  
有剪贴板的设备会先把原文写入剪贴板。

默认开启：`reader.edge_translation_enabled ~= false`。

## 用法

```lua
local Translate = require("translate")

Translate.isEnabled()
Translate.install()   -- main 里 hook Translator

-- 一般不直接调 edge；由 Translator 路径进入 popup
-- 需要裸请求时：
local Edge = require("translate.edge")
Edge.translate(text, source_lang, target_lang, cb)
```

划词菜单触发时可带 `from_highlight` / `index`，决定弹窗是否显示「存笔记」以及编辑哪一条。
