# ui/themes：主题与组件

月读自绘的一套界面组件，外加 paper / bold / soft 三套主题令牌。组件不使用 KOReader 的原生弹窗和控件外壳（ConfirmBox、ButtonDialog、Menu、InputDialog 等），
外观全部由令牌决定。

## 边界

- **自成一体**：只依赖 KOReader 自带模块，以及插件的基础设施 `utils.settings`、`utils.log`、`utils.perf`、`utils.paths`、`http.request`、`l10n` / `gettext`。
  不依赖 `ui/components` 等其他 UI 组件，删掉它们不影响这里。
- **组件只读令牌键，不判断主题 id**：换主题只换数据，组件代码没有 `if theme == "bold"`。
- **模块按 `xxx.init` 引用**：KOReader 给插件的 `package.path` 只有 `<plugin>/?.lua`，没有 `?/init.lua`。所以要写成 `require("ui.themes.init")`，不能写成 `require("ui.themes")`。

## 快速上手

```lua
local Theme = require("ui.themes.init")
local Confirm = require("ui.themes.widgets.confirm")
local Text = require("ui.themes.widgets.text")

local title = Text.line("title", "书名", { width = Theme.px(200) })

Confirm:new{
    text = "确定删除这本书？",
    ok_text = "删除",
    ok_callback = function() end,
}:show()
```

## 主题 API（`init.lua`）

| 函数 | 说明 |
|---|---|
| `Theme.ids` | `{ "paper", "bold", "soft" }`，顺序即展示顺序 |
| `Theme.get(id)` | 取指定主题的令牌表；id 不存在直接报错 |
| `Theme.current()` | 当前主题，读 `display.ui_theme`，未设或写错回落 paper |
| `Theme.scale()` | 当前缩放百分比，读 `display.ui_scale`，夹到 100–180，缺省 130 |
| `Theme.px(n)` | 逻辑像素转物理像素（DPI × 缩放）：0 保持 0，其余至少 1 |
| `Theme.fontSize(size)` | 逻辑字号只乘缩放，下限 10；DPI 由 `Font:getFace` 自己乘 |
| `Theme.face(name, size)` | 等于 `Font:getFace(name, Theme.fontSize(size))` |
| `Theme.root()` | 插件根目录（带尾斜杠），图标字体和相对路径图片按它解析 |

### 设置键

都在 `display` 段里：

| 键 | 取值 | 作用 |
|---|---|---|
| `ui_theme` | `paper` / `bold` / `soft` | 当前主题 |
| `ui_scale` | 100–180，缺省 130 | 全局尺寸和字号缩放，和旧桌面共用这个键 |
| `mesh_mask` | 布尔，缺省开 | 弹窗是否画网状遮罩；关掉后照样吞掉点击 |

## 令牌

令牌是纯数据，不依赖 KOReader。三套主题的键集合和取值类型必须完全一致，`tests/ui/themes/init_spec.lua` 会校验。

- **颜色**：8 位灰度，`0x00` 黑到 `0xFF` 白。组件里经 `Blitbuffer.Color8` 转成颜色。
- **尺寸**：逻辑像素，组件里经 `Theme.px` 转换。
- **字号**：逻辑字号，组件里经 `Theme.face` / `Theme.fontSize` 转换。

| 组 | 键 | 用途 |
|---|---|---|
| `color` | `page` `ink` `muted` `faint` `disabled` `rule` | 页面底、主文字、次要文字、提示、不可用、分割线 |
| `card` / `raised` / `dialog` / `image` | `bg` `border` `border_color` `radius` `shadow` `shadow_color` | 四种表面：普通卡片、主角卡片、弹窗面板、图片框。`shadow` 是右下偏移，0 不画 |
| `control` | `height` `radius` `border` `icon` | 按钮、chip、输入框共用的几何。`radius` 超过半高就是胶囊，`icon` 是图标逻辑字号 |
| `button` | `normal` / `primary` / `ghost`，各含 `bg` `ink` `border_color` | 按钮三种变体。没有 `bg` 不填底，没有 `border_color` 不画边 |
| `selected` | `bg` `ink` `mark` | 选中项（当前 Tab、列表当前项）。`mark > 0` 时在底部画指示条 |
| `progress` | `height` `radius` `border` `border_color` `track` `fill` | 进度条 |
| `font` | `caption` `body` `title` `hero` | 四种字号角色 |
| `space` | `xs` `sm` `md` `lg` | 间距，都是 4 的倍数 |
| `row` | `height` `divider` | 列表行高、分割线粗细；0 表示不画线 |

### 三套主题

| 主题 | 风格 | 适合 |
|---|---|---|
| `paper` 纸本 | 白底细线、近直角、无阴影，几乎只有黑白 | 默认。局部快刷残影最少，夜间反色后依然干净 |
| `bold` 高对比 | 粗黑边、纯黑硬阴影、直角，选中项整块反色 | 灰阶差的老屏、强光下。大面积黑块切换残影明显，需要全刷 |
| `soft` 柔和 | 浅灰卡片、大圆角、胶囊控件，只有主角卡片和弹窗带浅灰阴影 | 和旧桌面观感最接近 |

## 组件

都在 `widgets/`。组件一律在内部调用 `Theme.current()` 取当前主题，调用方不传主题。颜色类参数（如 `Text.line` 的 `opts.color`）要传令牌值时，自己取 `Theme.current().color.muted` 这类值。

`opts` 里的 width / height 都是**物理像素**（已经过 `Theme.px`），只有文件头注明“逻辑像素”的字段例外。

### 基础件

| 模块 | 用法 | 说明 |
|---|---|---|
| `box` | `Box:new{ style = t.card, width, height, padding, child }` | 表面：底色、边框、圆角、阴影全部自绘，不走 FrameContainer。阴影计入尺寸，但不占 width/height。尺寸在 init 定死，内容变了要重建 |
| `text` | `Text.line(role, text, opts)` / `Text.box(role, text, width, opts)` | 单行（超宽截断）/ 多行。`opts.color` 是灰度令牌。`Text.box` 放在非白表面上必须传 `opts.bg` |
| `icon` | `Icon.widget{ name, size, color }` / `Icon.label{ name, text, direction, ... }` | Material Symbols 字体图标，`name` 写图标原名。名字写错会显示英文字面 |
| `button` | `Button:new{ text, icon, variant, width, enabled, callback }` | 变体 `normal` / `primary` / `ghost`。`enabled = false` 时置灰并吞掉点按 |
| `tap` | `Tap.wrap(widget, fn)` | 给任意控件套点击区；`fn` 为 nil 时原样返回 |
| `progress` | `Progress:new{ width, percent }` + `:setPercent(n)` | 进度条，调用方负责 `setDirty` |
| `image` | `Image.widget({ src, width, height, fallback, style })` | 图片框，见下文“图片” |
| `mask` | `Mask:new{ dimen }` | 网状遮罩，受 `mesh_mask` 开关控制；一般由 Modal 自己用 |

### 布局件

| 模块 | 用法 | 说明 |
|---|---|---|
| `row` | `Row.widget({ width, icon, image, title, subtitle, status, selected, enabled, callback })` | 设置页和列表的一行。`status` 可以是文字，也可以直接是控件；缩略图高度夹到行内 |
| `titlebar` | `TitleBar.widget({ width, title, subtitle, left_icon, right_icon, ... })` | 标题栏，替代 TitleBar |
| `tabbar` | `Tabbar.widget({ width, tabs, active, on_tab })` | 底栏 Tab；点当前格不回调 |
| `pager` | `Pager.widget({ width, page, pages, on_prev, on_next, dots })` | 翻页条，到头的一侧按钮置灰 |

### 弹窗

都继承 `modal`，调用 `:show()` 显示、`:close()` 关闭；关窗后 `close_callback` 调用一次。

| 模块 | 替代 | 用法 |
|---|---|---|
| `confirm` | ConfirmBox | `Confirm:new{ text, ok_text, ok_callback, cancel_callback }` |
| `toast` | InfoMessage | `Toast:new{ text, timeout }` |
| `sheet` | ButtonDialog | `Sheet:new{ title, items }`。`items` 每项可以是按钮、`{ buttons = {...} }` 一行多按钮，或 `{ separator = true }` 分组空隙 |
| `list` | Menu / Popup.list | `List:new{ title, items, multi, centered, on_select, on_toggle }`，分页不滚动 |
| `input` | InputDialog / MultiInputDialog | `Input:new{ title, fields, callback }`；编辑内核仍是 KOReader InputText（虚拟键盘和中文输入法挂在它上面） |
| `spin` | SpinWidget / DateTimeWidget | `Spin:new{ title, fields, callback }`，一列或多列 |
| `progress_dialog` | ProgressbarDialog | `ProgressDialog:new{ title }` + `:update(text, done, total)` |
| `qr` | QRMessage | `QR:new{ title, text, caption }` |
| `text_viewer` | TextViewer | `TextViewer:new{ title, text }`，全屏分页 |

#### Modal 的定位与关闭

- `anchor = "center"`：居中（缺省）。
- `anchor = "top"`：贴顶，给虚拟键盘让位。
- `anchor = button.dimen`（一个矩形）：贴在它下方弹出，放不下就翻到上方，左右夹进屏内。适合按钮下拉菜单，一般配 `mask = false`。
- 点面板外或按返回键：`dismissable = true` 时调 `dismiss()`（缺省关窗，确认框这类子类覆盖为“取消”），否则只吞掉事件。
- `close_on_tap = true`：面板内外任意点按都关窗，用于提示、进度、二维码这类没有交互的面板。

#### 写一个自定义弹窗

```lua
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")

local Notice = Modal:extend{ text = nil }

function Notice:init()
    Modal.init(self)
    local t = self.theme
    self:setDialog{
        title = "提示",
        body = Text.box("body", self.text, self:innerWidth(), { bg = t.dialog.bg }),
        buttons = { { text = "知道了", variant = "primary", callback = function() self:close() end } },
    }
end

Notice:new{ text = "已同步" }:show()
```

- `setDialog{ title, body, buttons }` 是标准面板，`body` 的宽度用 `self:innerWidth()`。
- 完全自定义的面板用 `setPanel(box)`。

## 图片

`image.lua` 负责主题外观：表面令牌、边框内缩、占位文案。`image/core.lua` 负责内核：下载、磁盘缓存、分帧解码、位图缓存。

```lua
local img = Image.widget({
    width = w, height = h,
    src = "https://…",      -- 也可以是绝对路径，或插件内相对路径（如 "logo.png"）
    fallback = "书名",       -- 未就绪或失败时显示的文案
})
img[1]:cancel()              -- 只取消这一张的下载
```

- **网络图片**：磁盘缓存命中直接出图，否则先下载再出图。
- **异步出图后的刷新**：图片一律先换进占位。只有在它画上过屏幕、并且仍在显示中的窗口里时，才刷新它所在的顶层窗口，而且只刷图片自己那块区域。窗口关了或翻页换掉了就不刷新，下次上屏会直接画出来。调用方不用传 `show_parent`。
- `Image.fetchAsync(url, headers, cb)`：只下载不显示。
- `Image.invalidate(path)`：原地替换过的文件，之后绕过位图缓存。
- `Image.await(root, cb)`：等一棵控件树里的图片全部落定后回调（离屏渲染用）。
- 图片表面的圆角统一为 0：位图是方的，圆角框压不住四角。
- UI 图标用 `icon`（字体图标），不要用图片组件。

## 扩展约定

**新增组件**
- 放在 `widgets/`，文件头按 `--[[-- … @module koplugin.book.ui.themes.widgets.xxx --]]` 写，画上布局草图和调用示例。
- 颜色、尺寸、字号一律从令牌取，经 `Theme.px` / `Theme.face` 转换，不写死像素。
- 有状态、有生命周期的用 `Widget:extend` + `:new`；无状态的控件工厂写成 `Xxx.widget(opts)`，在函数内部调用 `Theme.current()`，不让调用方传主题。
- 不引用 `ui/components` 等主题以外的 UI 组件。

**新增或修改令牌**
- 三套主题要同时加同一个键，否则 `init_spec` 失败。
- 组件只读键；需要按主题变化的行为，放进令牌数据里表达，不在组件里判断主题 id。

**新增主题**
- 新建 `<id>.lua`，键集合和现有主题一致，再把 id 加进 `init.lua` 的 `Theme.ids`。

## 测试与演示

- 测试：`./tests/run.sh tests/ui/themes/*_spec.lua tests/ui/themes/widgets/*_spec.lua tests/ui/themes/widgets/image/*_spec.lua`（runner 只收文件，可以传多个）。组件测试用 `tests/support/widget_stubs.lua` 的最小 KOReader 桩，在每个 spec 顶部调用 `Kit.install(id)`，中途用 `Kit.use(id)` 切主题。
- 演示：`book.koplugin/demo/`，打包时由 `tools/package.sh` 排除。开发时文件管理器菜单「月读」下面有「主题组件演示」入口，可以切换主题、查看所有组件。
