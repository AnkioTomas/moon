# remote/ — 远程管理

路径：[`book.koplugin/remote/`](../../book.koplugin/remote/)。

局域网 HTTP：文件管理、远程输入、剪贴板、设置。设置入口在桌面「远程管理」；Web 内另有文件管理页。

| 文档 | 讲什么 |
|---|---|
| 下文（本页） | 生命周期、受管根、怎么启停 |
| [`server`](server.md) | HTTP 状态机与路由装配 |

## 设计

- 模块级**单例**：FM / Reader 两个插件实例共享一份 server。
- `server.lua` 零 UI 依赖；KOReader UI 全部在 `init.lua` 函数内延迟加载（测试可只碰 server）。
- 一切 FS IO 由 init 注入 handler；上传走 raw body（非 multipart）。
- HTML/CSS/JS **静态**下发，不做模板注入；配置经 `/api/config`；样式跟随系统夜间模式。
- suspend 停服，resume 按 `_resume` 标记恢复。Kindle 防火墙打孔端口记 `_punched_port`：stop 必须用它拆规则（运行中改端口会泄漏旧规则）。

### 受管根目录

全部 `realpath`，堵住软链逃逸：

- KOReader 数据目录的上级
- 书籍根（local 配置 path / `home_dir`）
- 字体、插件、本插件、截图目录、壁纸目录等

KOReader 根、字体、插件、设置、Book 数据及书籍根：**不可删除或移动**。

### IO 策略

| 操作 | 方式 |
|---|---|
| 下载、单元 metadata | 直接 lfs/os |
| 目录扫描、递归删除、跨设备复制 | 串行 worker 队列 |
| 上传 | 先临时文件再移入；重名加 ` (n)`；跨设备退化为后台流式复制 |

---

## 用法

```lua
local Remote = require("remote")

Remote.start()    -- 设置页开关 / autostart
Remote.stop()

-- main.lua：KOReader onSuspend/onExit → 模块生命周期
function BookPlugin:onSuspend()
    Remote.onPause()
end
function BookPlugin:onResume()
    Remote.onResume()
end
function BookPlugin:onExit()
    Remote.onDestroy()
end
```

路由拆分约定：`file.lua` / `input.lua` 等函数**首参即 self**，由 server 装配为 `_route*`，**不要**反向 require server。

静态页在 `remote/html/`：`index.html`（入口）、`file.html`、`input.html`。
