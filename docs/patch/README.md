# patch/ — KOReader 核心补丁

路径：[`book.koplugin/patch/`](../../book.koplugin/patch/) + [`patches/`](../../book.koplugin/patches/)。

给 KOReader 核心打可选补丁（如翻页动画），安装前备份原文件，失败可回滚。

## 设计

- `patch/manager.lua`：安装 / 卸载 / 备份目录（`$DATA/.moon/backups/patches/<feature>/`）
- `patch/page_turn_animation.lua`：具体补丁之一
- `patches/`：补丁载荷文件

补丁不是业务功能开关的常规路径；改的是宿主文件，必须可逆。

## 用法

```lua
local Manager = require("patch.manager")

Manager.install("page_turn_animation")
Manager.uninstall("page_turn_animation")
Manager.isInstalled("page_turn_animation")
```

main 初始化时 `patch.manager.onCreate` 顺带跑各补丁门面的启动自检（如翻页动画）。失败要保留备份并报真实错误，不能留下半应用内核。
