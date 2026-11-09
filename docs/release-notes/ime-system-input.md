# 输入法改造发布说明

- 范围：ticket 07–11（输入方式契约、Android 后端、桌面 / WSL 后端、dex 构建安全、文档发布）
- 适用：`book.koplugin`（KOReader 2026.07+）
- 状态：随下一次插件版本发布
- 设计记录：[ADR 0002](../adr/0002-system-ime-platform.md)

## 一句话

Android 用系统输入法（微信输入法 / Gboard / 搜狗）替代自绘键盘，Debian / Windows /
macOS 走 SDL 系统文本输入，WSL 只支持 WSL 内安装的 fcitx5；Kindle / Kobo /
PocketBook 等墨水屏继续使用 KOReader 自带键盘。设置入口统一为
**设置 → 系统 → 输入法**。

## 本次改动

### 统一入口与默认值

- 只保留一个「输入法」入口，删除独立的「系统输入法」入口。
- 页面内用「输入方式」在 **系统输入法 / KOReader 输入法** 之间切换，切换后立即保存、
  重启后保持。
- **首次安装 / 未选择过时，一律默认 KOReader 输入法**；系统输入法是手动打开的可选项。
- 选择「系统输入法」后各平台的输入通路：

  | 平台 | 输入通路 |
  |---|---|
  | Android 手机 / 平板（非墨水屏） | 内嵌 dex 隐藏 `View` + `InputConnection` → 文件快照 → Lua |
  | Debian / Linux | SDL3 系统文本输入（fcitx5 / ibus） |
  | Windows | SDL3 + 微软拼音等系统输入法 |
  | macOS | SDL3 + macOS 输入法 |
  | WSL | SDL3 + WSL 内 fcitx5（XIM） |
  | Kindle / Kobo / PocketBook、Android 电纸书 | 不支持；固定 KOReader 输入法 |

- 墨水屏（含 Android 电纸书）无条件使用 KOReader 输入法，不显示「输入方式」行。
- 旧版 `features.system_ime.enabled` 只用于一次性迁移：显式开启过 → `system`，
  其余（含新装）→ `builtin`；迁移后旧键不再参与计算。

### 真机修复（2026-11-09）

- 系统输入法下前几次选词偶尔上不去：轮询把输入法上屏的文本写进输入框后不再回写隐藏
  `EditText`，避免 `imm.updateSelection` 重置组合串。
- 键盘高度校正触发 `InputDialog.reinit` 时会丢尚未轮询的上屏动作：重建前先 flush 到输入框。
- 同一高度反复 reinit 导致保存笔记时整页狂闪：保留 `last_height`，同一高度只通知一次。

### 输入路由与例外

- system 模式下不弹内置 VK、不构建内置候选栏、不改写全局键盘布局；
  `pinyin_enabled` 的值保留，供切回 builtin 时恢复。
- 数字字段（`input_type == "number"`）、密码字段（`text_type == "password"` /
  `is_password_type`）、只读字段始终走 KOReader 自带键盘：数字键盘、密码遮罩、
  只读不弹键盘。
- Android 上屏文字直写当前 `inputbox`（`addChars` / `delChar` / `setText`），
  不再经过 `vk:addChar` / `vk:delChar`，避免内置候选栏把系统文字当拼音码拦截。
- Android 键盘高度 `0` 视为已收起：清活动状态并通知对话框重新排版。
- 系统输入法不可用时本次会话自动回退内置键盘：Android 先收系统键盘再回退，并留
  约 180ms 的延迟安全网避免系统键盘与 VK 同现，弹出「系统输入法不可用，已切回内置
  键盘」，设置页显示「上次启动未就绪」；WSL 未装 fcitx5 时自动回退，并在设置页给出
  `fcitx5 --disable=wayland` + `XMODIFIERS=@im=fcitx` 的指引。
- 切换焦点 / 关闭输入对话框 / 收起键盘时复位未提交的组合串，避免预编辑串到下一个输入框。

### 桌面 / WSL 测试入口

- 桌面 / WSL 选择系统输入法后，设置页出现「测试系统输入法」。
- 测试会打开一个真实输入框：收到非空文字记「通过」，空文本或取消记「未通过」，
  结果显示为未测试 / 通过 / 未通过，只用于展示，不改变输入方式。

### dex 构建与安全

- koboard v0.6.5（MIT，commit `d49f0981cdafd8a3e387a7f9e6be5d45f88cea08`）Java
  源码 vendored 在 `book.koplugin/features/system_ime/java/`，上游 tag / commit /
  文件哈希见 `upstream.md`、`THIRD_PARTY.txt`。
- dex 二进制**不进 git**；仓库提交校验值
  `6129e4f3acde998617224e9291690b151e1aeffdf4960087fb45210b35e5d1e2`。
- `tools/build_android_ime_dex.sh` 按固定工具链构建：JDK 21 + build-tools 36.1.0 +
  platform android-36；哈希不一致时拒绝落盘。本轮未在本地跑通完整复现构建，本地
  重建依赖同一套工具链。
- CI 的 `android-ime` job 构建两次、逐字节比对、校验 sha256 并跑
  `tools/audit_android_ime_dex.sh` 的 API 审计；release 在打包前执行同一套构建、
  校验和审计（两处共用 `.github/actions/android-ime-dex`）。
- 运行时再次校验 sha256，只加载已知类，dex 复制到应用私有 cache 并 `chmod 444`，
  临时文件 + rename 原子替换，不联网下载。

## 已知限制

- **WSL 不能用 Windows 输入法**：WSLg 没有可用的 Windows-IME 通路；只支持 WSL 内
  fcitx5 走 XIM。需要先安装 fcitx5，用 `fcitx5 --disable=wayland` 启动，并设置
  `XMODIFIERS=@im=fcitx` 后再启动 KOReader。
- **Windows / macOS 人工验证未完成**：代码走 SDL 系统文本输入，但本轮没有真实
  Windows / macOS 桌面验收；`SDL_SetTextInputArea` 的候选窗锚定效果因平台而异，
  文档不把这两端写成已通过。
- **Android ROM 差异**：MIUI / HyperOS、AOSP、类原生和电纸书的 `DexClassLoader`、
  键盘高度回传、返回键收起、前后台 / 旋转 / 分屏行为可能不同。失败时按设计回退
  内置键盘并记录状态，但仍需真机矩阵确认。
- **Android 电纸书按墨水屏处理**：Kindle / Kobo / PocketBook 以及 Android 电纸书
  固定使用 KOReader 输入法，不提供系统输入法选项。
- **预编辑不显示在输入框**：v1 不接 `SDL_EVENT_TEXT_EDITING`，拼音组合只在系统
  候选窗显示，上屏后才进输入框。
- **候选窗锚点是尽力而为**：`SDL_SetTextInputArea` 符号、窗口或输入框坐标缺失时
  只跳过锚点，文本输入仍然可用，但候选窗位置可能仍由系统决定。
- **dex 构建依赖固定工具链**：JDK / build-tools / platform 版本变化会导致哈希漂移；
  本地重建需按 `tools/build_android_ime_dex.sh` 的环境变量准备工具链。仓库未声称
  已在本地跑通完整复现构建，由 CI 构建两次并比对。

## 升级注意

- 老用户的原「系统输入法」开关会迁移：显式开启过的沿用系统输入法，其余（包括新装）
  默认 KOReader 输入法。
- 升级后第一次打开「输入法」页，可按需切换输入方式；系统输入法不再是默认。
- 发布包中的 dex 由 CI 构建并校验；源码包不包含 `classes.dex`，自行打包时请先跑
  构建和审计脚本。

## 验证矩阵

自动化结果：`./tests/run.sh` → **695 passed, 1 skipped, 0 failed**（需要本机
`koreader/` 外部库；无该目录时仅 `ui/widget/imagewidget` stub 用例环境性失败）。
l10n 审计：输入法相关文件共 65 条唯一 `_()` 源字符串在 `l10n/en.lua` 与
`l10n/zh_TW.lua` 中均有译文，无重复键；`tests/l10n/dicts_spec.lua` 全绿。

| 环境 | 检查项 | 状态 |
|---|---|---|
| Android 真机（MIUI + AOSP / 类原生，Android 11 / 14 / 15） | 微信输入法 / Gboard / 搜狗中文、英文、数字、密码、只读；前后台、旋转、分屏、返回键收起、长文本、表情、回退 | **未执行（需真机）** |
| Android 电纸书（Boox / 海信 / HiBreak 等） | 自带键盘、候选栏、收起键、布局、词库零回归；系统输入法按墨水屏策略不出现 | **未执行（需设备）** |
| Debian + fcitx5（X11） | 系统模式中文上屏、无 VK、候选窗贴输入框、关闭再开仍可输入 | **未执行（需真实桌面）** |
| Debian + fcitx5（Wayland） | 同上 | **未执行（需真实桌面）** |
| Windows + 微软拼音 | 系统模式中文上屏、无 VK、候选窗位置 | **未执行（需真实桌面）** |
| macOS + 自带输入法 | 系统模式中文上屏、无 VK、候选窗位置 | **未执行（需真实桌面）** |
| WSL + fcitx5（XIM） | `XMODIFIERS=@im=fcitx` 后中文上屏；未装 fcitx5 时回退 + 指引 | **未执行（当前 WSL 未安装 fcitx5；检测分支有单测）** |
| Kindle / Kobo / PocketBook | 自带键盘、候选栏、收起键、布局、词库零回归 | **未执行（无设备；builtin 路由有单测）** |
| 自动化 | 单元测试、l10n 键集 / 重复键 / 源码覆盖、dex 审计 fixture | **通过** |

> 上表中标「未执行」的项目是人工 / 真机验收项，不因单元测试通过而视为已通过。
> 详细记录见 `.scratch/ime-system-input/verification-11.md`（不随仓库发布）。
