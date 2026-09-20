# utils/ — 原语

路径：[`book.koplugin/utils/`](../../book.koplugin/utils/)。无业务状态；文字处理禁止在业务里再写一份。

| 模块 | 用途 |
|---|---|
| `paths` | `$DATA/.moon/` 布局、`dbPath()`、`md5(stable_id)` 安全缓存目录 |
| `settings` | common / 分源 / 分功能配置 |
| `text` | trim、路径、BOM/换行、XML、URL/form、段落化 |
| `log` / `perf` / `timing` | 日志与计时 |
| `font` | 字体辅助 |

```lua
local Paths = require("utils.paths")
Paths.dbPath()
Paths.bookWorkDir(stable_id, source_id)  -- 内部 md5(stable_id)
Paths.coverPath(stable_id, source_id)

local Text = require("utils.text")
Text.trim(s)
```

类型桩（KOReader / FFI）：`book.koplugin/types/`。业务类型写在拥有模块。i18n：源字符串即简体中文；`l10n/zh_TW.lua`、`en.lua`。版本文件必须叫 `bookversion.lua`。

测试写 `test/` 沙箱（`KO_HOME`），禁止写真实 `config/`。
