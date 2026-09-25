# lockscreen.compose — 合成流水线

代码：[`lockscreen/compose.lua`](../../book.koplugin/lockscreen/compose.lua) + `background` / `layout` / `render` / `components/`。

## 设计

```text
Compose.plan()
  → Background.ensure（与主体的 ensureText 并行）
  → Layout.panel 算面板矩形 → components/<id>.blocks(rect)
    （quote 主体自带动态高度，full_screen 主体用整屏矩形，二者不走 Layout.panel）
  → render → output_path（通常 compose.png）
```

direct 资源直接返回原图路径，不经 compose.png。

计划轴：`component × background × position × wide` → 决定输出路径与是否可 direct 出原图。

缓存键通常包含：日期、布局、主体 id、背景 `source_path`、可选 `component.cache_key()`（例如封面同日变更也要重合成）。

`cacheValid(plan, force)`：`lock_screen_day == dayKey` 且资源新鲜且输出文件有效。

生成策略：先写完整新文件再替换当前屏保图；失败保留上一张可用图。设置 `revision` 变化则丢弃过期回调。

能复用的画面（引言、书封、进度、柱图）放 `ui/components/`，锁屏经 `kind=widget` 嵌入，不要复制桌面拼装。正在显示的 Desktop 实例不要交给 blocks 消费。

---

## 用法：新增主体

```text
1. lockscreen/components/foo.lua
   - 导出 blocks(plan, …) 或注册表要求的接口
   - 可选 cache_key()
2. components/base.lua 的 COMPONENT_MODULES 注册一行
3. 设置页经 Components.options() 自动出现
```

背景新增同理：`background` 选项表加一项 + 实现 ensure，设置页经 `Background.options()` 自动出现。

```lua
local Compose = require("lockscreen.compose")
local plan = Compose.plan()
if Compose.cacheValid(plan, force) then
    -- 复用
else
    Compose.build(plan, function(ok, err, path) end)
end
```

### 注意

- 非 force 且设置 `revision` 未变时，`init.refresh` 不打断已在跑的 job；revision 已变则取消旧 job 重跑。
- 回调里检查 `Settings.isCompose()` 与 `revision`，用户中途改设置则丢弃。
