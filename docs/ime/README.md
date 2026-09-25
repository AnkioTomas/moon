# ime/ — 中文输入法增强

路径：[`book.koplugin/ime/`](../../book.koplugin/ime/)。

| 文档 | 讲什么 |
|---|---|
| 下文 | 开关、布局、候选栏 |
| [`dictionary`](dictionary.md) | 词库路径与下载 |

## 设计

四种方法：**拼音、五笔、仓颉、注音**。复用 KOReader `zh_CN` 布局，不新增 layout、不包装 `generic_ime`。  
差异只在 `registry` 的按键映射（仓颉/注音改键帽）和词库文件；候选状态机不按输入法复制分支。

候选栏：`candidate_bar` hook `VirtualKeyboard` 的 `init` / `addKeys` / `addChar` / `delChar`；`Strip` 替换中文键盘首行；经 `raw_method_call` 直写输入框。

配置键历史原因仍叫 `pinyin_enabled`。启用时：

1. 若尚未快照，把当前 `keyboard_layouts` **浅拷贝**存到 `book_pinyin_previous_keyboard_layouts`
2. 收窄为 `{ "en", "zh_CN" }`

禁用时恢复快照。词库不可用时拒绝开启。

---

## 用法

```lua
local IME = require("ime")

IME.isEnabled()
IME.setLayout("wubi")      -- 或 pinyin / cangjie / zhuyin
IME.layout()
IME.layouts()              -- 供设置页

-- main 初始化
require("ime.candidate_bar").install({ enabled = IME.isEnabled })  -- 由 IME.onCreate / setEnabled(true) 调用
```

设置页：总开关 + 当前方案选择 + 词库下载入口（见 [`dictionary`](dictionary.md)）。
