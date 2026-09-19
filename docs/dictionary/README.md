# dictionary/ — StarDict 词典

路径：[`book.koplugin/dictionary/`](../../book.koplugin/dictionary/)。

接管 KOReader「管理词典 / 下载词典」，保留查词事件与划词按钮。关闭后完整回退原生。

## 设计

- `init.lua`：开关、菜单顺序（下载项插在查词后面）、hook ReaderDictionary
- `manager.lua`：下载、安装、启停词典包（重活走 `workers`，`heavy`）
- `ui.lua`：下载/切换 UI；查词弹窗点标题栏可切换词典（对齐翻译弹窗切语言）
- 词典包与天气图标类似，可走 CDN；词库文件不进四域同步

默认开启（`reader` 设置里关）。

## 用法

```lua
local Dict = require("dictionary")

Dict.isEnabled()
Dict.install()    -- main 初始化时 hook
Dict.uninstall()  -- 或 setEnabled(false) 回退原生

-- 管理/下载由菜单进入；业务代码一般只调 init
```

安装失败要能回滚半下载文件；worker 子进程只解压/写盘，主进程再刷新词典列表。
