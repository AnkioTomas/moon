# lockscreen/ — 组合锁屏

路径：[`book.koplugin/lockscreen/`](../../book.koplugin/lockscreen/)。

| 文档 | 讲什么 |
|---|---|
| 下文 | 模式、refresh、缓存 |
| [`compose`](compose.md) | 计划轴、流水线、新增主体 |

## 设计

`lock_screen` 设置：

| 值 | 行为 |
|---|---|
| `ko` | KOReader 默认屏保，月读不合成 |
| `compose` | 月读生成 `compose.png` 并接管 `screensaver_*` |

生命周期在 `init.lua`：编排在飞任务、按天重下背景、设置变更、suspend/resume。图 URL 来自 [`online`](../online/README.md)；落盘与按日校验在 `background.lua`。

---

## 用法

```lua
local Lockscreen = require("lockscreen")

-- force=true 打断在飞任务；reason 仅打日志
Lockscreen.refresh(function(ok, err) end, false, "network_connected")

-- main：suspend 前、网络恢复、设置变更、按天
```

设置页：

- 遍历 `backgroundOptions` / `componentOptions`，不要硬编码
- 改模式或主体后 `refresh(..., true, "settings")`

非 compose 模式：`refresh` 直接跳过。缓存命中：直接 `Settings.applyCover(path)`，不重建。
