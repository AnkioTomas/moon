# update/ — 插件自更新

路径：[`book.koplugin/update/`](../../book.koplugin/update/)。

查 GitHub Release、下载校验、完整替换插件目录。  
**自动检查只提示**，不会自动下载安装。

## 设计

- `init.lua`：查版本、弹窗、进度条、与设置开关
- `install.lua`：解压/替换（Job）
- API：`https://api.github.com/repos/AnkioTomas/moon/releases/latest`
- 检查间隔默认 24h；当前版本来自 `bookversion`
- 自动检查入口：`Desktop:onResume` → `Update.autoCheck`（仅提示，不自动装）
- `_checking` / `_installing` 防重入；在飞 job 可 cancel

版本文件必须叫 `bookversion.lua`（不能叫 `version.lua`，与 KOReader 冲突）。CI 在 `v*` tag 注入版本。

## 用法

```lua
local Update = require("update")

Update.checkAsync({ interactive = true })  -- 设置页「检查更新」
-- 静默检查：Desktop:onResume → Update.autoCheck（仅有新版本才提示）

-- 用户确认后内部走 download + Install
```

安装失败不得留下半替换的 `book.koplugin/`；先落到临时目录再切换。
