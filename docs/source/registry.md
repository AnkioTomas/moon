# source.registry — 源注册表

代码：[`source/registry.lua`](../../book.koplugin/source/registry.lua)。

## 设计

- 工厂表 `FACTORIES` + 展示顺序 `ORDER`（local 排前：混合 → 本地 → 在线）。
- **同一时间一个活跃实例**（`_active`）。`current()` 严格按配置创建，不做静默 fallback。
- `resolve(id)`：与 current 同 id 则复用；否则在 `_resolved` 里建/取**非活跃**属主实例，**不改**用户选择的活跃源。这是「打开旧书不串源」的关键。
- 切换：先 `create` 候选 → 成功再 `activate` 原子替换 → `close` 旧实例。
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
Registry.afterAuthChanged(plugin)   -- 登录态变更：invalidate + plugin:onSourceChanged()
```

### API

| API | 说明 |
|---|---|
| `meta(id)` / `list()` | 只取 meta，不构造实例 |
| `listEnabled()` | picker 与设置页用这个 |
| `isEnabled(id)` | 活跃源恒 true |
| `setEnabled(id, on)` | 首次写入时用「当前全部启用」初始化集合；禁用活跃源返回 `false, err` |
| `create(id)` | 构造新实例（不激活） |
| `current()` | 活跃实例 |
| `resolve(id)` | 属主实例（可非活跃） |
| `setActive(id)` | 候选创建 + 原子切换；返回实例或 `nil, err` |
| `activate(source, id)` | 底层替换（一般用 setActive） |
| `invalidate()` | 清空并 close 全部缓存实例（活跃 + 属主） |
| `afterAuthChanged(plugin)` | 登录态变更后 invalidate 并通知桌面刷新 |

### 注意

- UI「当前源」和书「属主源」是两件事；同步进度用后者。
- `resolve` 禁止副作用改 `activeSourceId`。
