# source.registry — 源注册表

代码：[`source/registry.lua`](../../book.koplugin/source/registry.lua)。

## 设计

- 源 id 清单 `IDS` 即展示顺序（local 排前：混合 → 本地 → 在线），模块固定为 `source.<id>`。
- **每个 id 一个实例**，缓存在同一张表里。活跃源只是配置里的 id：`current()` = `resolve(activeId())`，不做静默 fallback。
- `resolve(id)`：按 id 建/取实例，**不改**用户选择的活跃源。这是「打开旧书不串源」的关键。
- 切换：`resolve` 成功后才写配置；旧实例不关（可能仍是打开中书籍的属主源），统一由 `invalidate` 释放。
- 源模块加载失败是代码缺陷，`meta` / `list` / `create` 直接抛出，不从列表里悄悄藏掉。
- `enabled_sources`：`nil` = 全部启用；活跃源恒视为启用（不能关自己）。

---

## 用法

```lua
local Registry = require("source.registry")

-- 设置页 / 顶栏
for _, meta in ipairs(Registry.listEnabled()) do
    -- meta.id / name / type ("book"|"chapter")
end

local source, err = Registry.setActive("wechat")  -- 成功返回新活跃实例
local ok, err = Registry.setEnabled("jdread", false)  -- 正好是活跃源时返回 false 和错误文案

-- 打开书、同步旧书
local source = Registry.resolve(book.source_id)
source:openBookAsync(identity, opts, cb)

-- 桌面当前源（是否已配置由调用方看 current:configured()）
local current = Registry.current()

Registry.invalidate()               -- 丢掉并 close 活跃实例与全部属主实例
Registry.notifyChanged()            -- 源配置变了：广播 KOReader 事件 SourceChanged，桌面 onSourceChanged 重建
Registry.reload()                   -- 登录态 / 连接配置变了：invalidate + notifyChanged
```

### API

| API | 说明 |
|---|---|
| `meta(id)` / `list()` | 只取 meta，不构造实例 |
| `listEnabled()` | picker 与设置页用这个 |
| `isEnabled(id)` | 活跃源恒 true |
| `setEnabled(id, on)` | 首次写入时用「当前全部启用」初始化集合；禁用活跃源返回 `false, err` |
| `create(id)` | 构造新实例（不进缓存） |
| `current()` | 活跃实例（`resolve(activeId())`） |
| `resolve(id)` | 属主实例（缓存复用，可非活跃） |
| `setActive(id)` | 实例就绪后写配置；返回实例或 `nil, err` |
| `invalidate()` | 清空并 close 全部缓存实例 |
| `notifyChanged()` | 同步广播 `SourceChanged`（换源、混合模式、书城开关、OPDS 配置）；桌面不在窗口栈上时无人处理 |
| `reload()` | 登录态或连接配置变更：`invalidate()` 后 `notifyChanged()` |

### 注意

- UI「当前源」和书「属主源」是两件事；同步进度用后者。
- `resolve` 禁止副作用改活跃源（`Registry.activeId()`）。
