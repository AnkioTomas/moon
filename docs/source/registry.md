# source.registry — 源注册表

代码：[`source/registry.lua`](../../book.koplugin/source/registry.lua)。

## 设计

- 源 id 清单即展示顺序：内置 `BUILTIN`（local 排前：混合 → 本地 → 在线，模块固定为 `source.<id>`），后接第三方源。
- 第三方源：KOReader 加载完全部插件（本插件已在 `PluginLoader.enabled_plugins` 里）后，首次访问注册表时扫一次 `enabled_plugins` 并缓存；加载期间（月读顶层模块被 require 时）只有内置源、不缓存。插件根目录有 `moon_source.lua` 就 dofile 成描述表，按插件加载顺序排在内置源之后。描述文件不合约定（`api` 不等于 `Registry.API`、缺 `meta`/`new`、id 不是 `ext.<name>`、与已登记 id 重名、加载抛错）记错误日志并跳过：第三方代码不能拖垮内置源。契约见 [`external`](external.md)。
- 第三方插件卸载后，它的 id 不再登记：活跃源退回 local，`create` / `resolve` 返回 `nil, err`，书库里的书留着（混合模式按启用源过滤，不显示），重装即恢复。
- **每个 id 一个实例**，缓存在同一张表里。活跃源只是配置里的 id：`current()` = `resolve(activeId())`，不做静默 fallback。
- `resolve(id)`：按 id 建/取实例，**不改**用户选择的活跃源。这是「打开旧书不串源」的关键。
- 切换：`resolve` 成功后才写配置；旧实例不关（可能仍是打开中书籍的属主源），统一由 `invalidate` 释放。
- 内置源模块加载失败是代码缺陷，`meta` / `list` / `create` 直接抛出，不从列表里悄悄藏掉。
- `enabled_sources`：`nil` 或集合里没有该 id（后装的源）= 启用，只有显式 `false` 是禁用；活跃源恒视为启用（不能关自己）。

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
| `setEnabled(id, on)` | 写显式 `true` / `false`；禁用活跃源返回 `false, err` |
| `external(id)` | 第三方源的描述表（含可选 `setting`）；内置源与未知 id 为 `nil` |
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
