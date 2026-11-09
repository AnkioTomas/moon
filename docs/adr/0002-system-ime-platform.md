# 系统输入法：Android 走 dex，桌面走 SDL，WSL 只认 fcitx5

## Context

moon 原来只有 KOReader 自带虚拟键盘一条输入路径。Android 的 NativeActivity 没有
`InputConnection`，只弹系统键盘不送字；桌面明明有 fcitx5 / 微软拼音 / macOS 输入法，
moon 仍然弹自绘键盘；旧的「输入法」和「系统输入法」还是两个互不相识的入口，同时开启
时系统上屏文字会被内置拼音候选栏拦截，出现串字。

## Decision

- **统一设置入口**：只保留 `设置 → 系统 → 输入法`，内部用「输入方式」在
  `system` / `builtin` 之间切换；支持系统输入法的平台不再有第二个输入法入口。
- **平台默认**：Android（非墨水屏）、Windows、macOS、Linux 默认 `system`；
  WSL、Kindle、Kobo、PocketBook 默认 `builtin`；所有墨水屏（含 Android 电纸书）
  无条件 `builtin`，忽略存储值且不显示「输入方式」。
- **Android 后端**：插件内嵌 koboard v0.6.5 dex，用带 `InputConnection` 的隐藏
  `View` 把系统输入法上屏文本经文件快照交给 Lua；文字直写 `inputbox`，不经过
  `vk:addChar/delChar`，避免被内置候选栏拦截。
- **桌面后端**：复用 SDL3 的 `startTextInput` → `TEXT_INPUT` → `InputText:onTextInput`
  通路，system 模式不弹 VK；`SDL_SetTextInputArea` 的 FFI 声明放在插件侧，
  符号或窗口缺失时只跳过候选窗锚点，不阻断文本输入。
- **WSL**：只支持 WSL 内安装的 fcitx5（XIM）。Windows 输入法在 WSLg 下不可用，
  不接社区 WSLg Windows-IME 桥；`XMODIFIERS` 不含 `fcitx` 时 `status()` 为
  `not_ready`，自动回退内置键盘并在设置页给出指引。
- **字段例外**：`input_type == "number"`、`text_type == "password"` /
  `is_password_type`、`readonly` 字段即使处于 system 模式也走内置键盘。
- **失败回退**：dex 缺失 / sha256 不符 / `DexClassLoader` 失败 / 系统输入法未就绪时
  本次会话回退内置键盘；Android 先隐藏系统键盘，并留约 180ms 的延迟安全网，避免
  已投递的 `showSoftInput` 与 VK 同现，同时写 `last_status = "not_ready"`；用户选择的
  `input_mode` 保持不变。

### dex 安全模型

- koboard v0.6.5 的 Java 源码 vendored 在
  `book.koplugin/features/system_ime/java/`，MIT 许可与上游 tag / commit / 文件哈希
  记录在 `upstream.md` 和 `THIRD_PARTY.txt`；本地未改源码。
- `classes.dex` 二进制**不进 git**（`.gitignore` 忽略），仓库只提交
  `classes.dex.sha256`：`6129e4f3acde998617224e9291690b151e1aeffdf4960087fb45210b35e5d1e2`。
- `tools/build_android_ime_dex.sh` 按固定工具链构建：JDK 21、Android
  build-tools 36.1.0、platform android-36，保留 `javac -source 8 -target 8` 与
  `d8 --min-api 1`；哈希不符时退出 1 且不落盘。本仓库不声称已在本地跑通完整
  复现构建，本地重建依赖同一套工具链。
- CI 的 `android-ime` job 构建两次、`cmp` 比对、`sha256sum -c` 校验提交的哈希，
  再跑 `tools/audit_android_ime_dex.sh` 的 API 白名单 / 黑名单审计（禁 `java.net`、
  `Runtime.exec`、反射、`System.load*`、动态类加载）；release 在打包前执行同一套
  构建、校验与审计（composite action，见 `.github/actions/android-ime-dex`）。
- 运行时 `features.system_ime.dex` 再次校验 sha256，只加载已知类
  `org.koreader.koboard.KOBoardShow`；dex 复制到应用私有 cache，临时文件 + rename
  原子替换并 `chmod 444`，不联网下载。

## Considered Options

- **只增强内置虚拟键盘**：拿不到微信 / Gboard / 搜狗的候选、联想、语音和剪贴板，
  也解决不了系统输入法与内置候选栏串字的问题。
- **修改 Android launcher / 自建 APK**：会换签名换包名，破坏 `rocks` OTA，成本高于
  插件内 `DexClassLoader`。
- **桌面 fork KOReader 加 FFI**：`SDL_SetTextInputArea` 可以在插件侧 `ffi.cdef` 补，
  v1 不改 fork。
- **WSLg Windows-IME 桥**：依赖替换 `WSLDVCPlugin.dll` / system distro，非官方、
  版本脆弱；只作为用户自担风险的脚注，不进入实现。
- **接 `SDL_EVENT_TEXT_EDITING` 做预编辑 UI**：v1 不做，拼音组合只在系统候选窗显示，
  上屏后才进输入框。

## Consequences

- 平台默认值与迁移只在一处（`features.ime.inputMode()`），设置页、候选栏和 VK 路由
  都读同一个有效模式，不会再出现两个开关互相打架。
- system 模式必须停用候选栏、恢复拼音前的 `keyboard_layouts`；回到 builtin 且
  `pinyin_enabled` 为真时再收紧布局，否则仍会串字。
- Android 行为受 ROM 影响（MIUI / HyperOS / AOSP / 电纸书）；真实上屏、键盘高度回传、
  前后台 / 旋转 / 分屏需要真机矩阵验证，失败路径统一回退并留状态。
- macOS / Windows 的 SDL 通路已按现有 API 实现，但候选窗锚定和系统输入法兼容性仍需
  真实桌面验证；文档不得把未跑过的平台写成已通过。
- 墨水屏保持内置键盘，零回归；Android 电纸书也按墨水屏处理，不提供系统输入法。
