# ui.lifecycle — 组件生命周期

代码：[`ui/lifecycle.lua`](../../book.koplugin/ui/lifecycle.lua)。

当前阶段模型（以代码为准）：

```text
new → Create → Resume ↔ Pause → Destroy
```

Resume / Destroy 会自动补中间阶段。处理函数抛错时状态**不回滚**。  
Pause / Destroy 进入前 bind 层先 `abortWork()`，取消已登记的 jobs 与 http。

业务事件用 `onEvent`，**不**改变生命周期状态，也不能经 `dispatch` 当分发业务事件。

---

## 用法

### 继承

```lua
local Lifecycle = require("ui.lifecycle")
local Comp = setmetatable({}, Lifecycle)
Comp.__index = Comp

function Comp:onCreate() end
function Comp:onResume()
    self:addHttp(Request.get(url, {}, function(res, err)
        if not self:uiReady() then return end
        -- 改 UI
    end))
end
function Comp:onPause() end
function Comp:onDestroy() end

local c = Comp:new()
c:onCreate()
c:onResume()
```

处理方法必须在 `new`/`attach` **之前**定义在原型上（bind 会包一层记状态）。不要事后覆盖 `onResume` 等绑定后的方法。

### 组合（Desktop 等）

```lua
local Desktop = InputContainer:extend{}

function Desktop:init()
    self.lifecycle = require("ui.lifecycle").attach(self)
end

function Desktop:onResume()
    -- self.lifecycle.state == "Resume"
    self.home:onResume()
end
```

组合模式把句柄登记到 **该对象自己的** `lifecycle:addHttp/addJob`，不要塞进 Desktop。Desktop 只转发阶段。

### API

| API | 说明 |
|---|---|
| `Lifecycle:new()` / `attach(owner)` | 继承构造 / 组合 |
| `onCreate` / `onResume` / `onPause` / `onDestroy` | 阶段入口 |
| `dispatch(stage, …)` | 按名分发；Resume/Destroy 带补全 |
| `uiReady()` | 仅 `state == "Resume"` |
| `addJob(job)` / `addHttp(handle)` | 登记；Pause/Destroy 取消 |
| `abortWork()` | 手动清空两张表 |

Job 认 `:cancel()`，HTTP 认 `.cancel()`；`abortWork` 两种都处理。

### 父子约定

- 父显式传递阶段；Lifecycle **不**自动遍历孩子。
- 切离 Home Tab → Pause Home；切回 → Resume。TopBar 常显，不随 Tab Pause。
- 恢复只针对当前可见子组件。

### 注意

- `uiReady` 不保证控件仍在、也不校验请求代次——代次由调用方管。
- 绕过 `new`/`attach` 的旧构造，直接调 `onResume` **不会**记状态。
- 测试：`./tests/run.sh tests/ui/lifecycle_spec.lua`
