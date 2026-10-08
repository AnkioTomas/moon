# ui/ — 呈现层

路径：[`book.koplugin/ui/`](../../book.koplugin/ui/)。

不拥有业务数据；页面只保存加载中、分页、筛选、请求代次。异步句柄挂在发起它的对象上，取消只杀那一条。禁止模块级 `_job`。

视觉基线在 [`ui/themes`](../../book.koplugin/ui/themes)：颜色、字号、间距、进度条都从那里取。无状态绘制在 [`ui/widgets`](../../book.koplugin/ui/widgets)。桌面壳在 [`desktop/`](../../book.koplugin/desktop)。

| 文档 | 讲什么 |
|---|---|
| [`desktop`](desktop.md) | 全屏壳、Tab、首页组件 |
| [`session`](session.md) | 阅读会话、切章、关书只推 |
| [`open`](open.md) | 按属主源打开物理文档 |

其它目录：

| 路径 | 用途 |
|---|---|
| `reader/` | 阅读面板、进度条、结束对话框 |
| `features/panel/` | 注入 KOReader 原生顶栏快捷动作 |
| `ui/widgets/` | 无状态绘制（封面、书卡、设置行、图表） |
| `ui/components/` | 有状态对话框（字体选择、任务、图片） |
| `ui/fonts/` | 字体：`init` 解析 id→文件→字体名与 UI 字体（唯一改 `Font.fontmap`）；`catalog` 列表与微信读书字体下载；`reader` 应用到阅读文档；`woff` 解包 |
| `desktop/` | 壳、顶栏、各页（不在 `ui/` 下） |
| `ui/themes/` | 主题和通用控件 |
