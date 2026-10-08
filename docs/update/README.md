# update/ — 插件自更新

路径：[`book.koplugin/features/update/`](../../book.koplugin/features/update/)（feature，登记在 `features/init.lua` 的 `list`）。

查 GitHub Release、下载校验、完整替换插件目录。  
**自动检查只提示**，不会自动下载安装。

## 设计

- `init.lua`：查版本、弹窗、进度条；feature 钩子只有 `onDestroy`（退出时取消在飞任务）
- `install.lua`：校验 SHA-256、解压、换位（在 `workers.job` 子进程里跑）
- API：`https://api.ankio.net/gh/repos/AnkioTomas/moon/releases/latest`（原样转发 GitHub API）
- 包体唯一信任根是 API 给的资产 `digest`；镜像只负责搬运字节，校验不过回落直连
- 检查间隔 24h；当前版本来自 `bookversion`
- 自动检查入口：`Desktop:onResume` → `Update.autoCheck`（仅提示，不自动装）
- `Update._job` 非 nil 即忙，防重入；在飞 job 可 cancel

版本文件必须叫 `bookversion.lua`（不能叫 `version.lua`，与 KOReader 冲突）。CI 在 `v*` tag 注入版本。

## 用法

```lua
local Update = require("features.update.init")

Update.manualCheck(plugin_root)  -- 设置页「检查更新」
-- 静默检查：Desktop:onResume → Update.autoCheck（仅有新版本才提示）
```

安装失败不得留下半替换的 `book.koplugin/`：先解压到同级暂存目录，换位失败回滚。
