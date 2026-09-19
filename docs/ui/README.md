# ui/ — 呈现层

路径：[`book.koplugin/ui/`](../../book.koplugin/ui/)。

不拥有业务数据；页面只保存加载中、分页、筛选、请求代次。异步句柄挂 Lifecycle，禁止模块级 `_job`。

视觉基线：[`ui/components/bookui.lua`](../../book.koplugin/ui/components/bookui.lua)（`UI.sz` / `face` / 灰阶 / Surface）。

| 文档 | 讲什么 |
|---|---|
| [`lifecycle`](lifecycle.md) | Create/Resume/Pause/Destroy、addJob/addHttp |
| [`desktop`](desktop.md) | 全屏壳、Tab、首页组件 |
| [`session`](session.md) | 阅读会话、切章、关书只推 |

其它目录：

| 路径 | 用途 |
|---|---|
| `ui/reader/` | 阅读面板、进度条、结束对话框 |
| `ui/panel/` | 注入 KOReader 原生顶栏快捷动作 |
| `ui/components/` | 墨水屏公共 Widget（首页/锁屏可复用） |
| `ui/desktop/home/` | 可钉组件 + registry |
| `ui/views/` | TopBar 等 |
