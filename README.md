<p align="center">
  <img src="logo.png" width="160" alt="月读 Logo">
</p>

<h1 align="center">月读 · Moon</h1>

<p align="center">
  <strong>把 KOReader 变成真正属于你的阅读系统</strong>
</p>

<p align="center">
  <a href="https://moon.ankio.net"><img alt="官网文档" src="https://img.shields.io/badge/文档-moon.ankio.net-1565C0?style=flat-square"></a>
  <a href="https://github.com/AnkioTomas/moon/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/AnkioTomas/moon?display_name=tag&sort=semver&style=flat-square"></a>
  <a href="https://github.com/AnkioTomas/moon/releases"><img alt="下载量" src="https://img.shields.io/github/downloads/AnkioTomas/moon/total?style=flat-square"></a>
  <a href="LICENSE"><img alt="GPL-3.0 许可证" src="https://img.shields.io/github/license/AnkioTomas/moon?style=flat-square"></a>
  <a href="https://koreader.rocks/"><img alt="KOReader 插件" src="https://img.shields.io/badge/KOReader-plugin-222222?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://moon.ankio.net/manual/start"><strong>从这里开始</strong></a> ·
  <a href="https://moon.ankio.net/jailbreak"><strong>Kindle 越狱</strong></a> ·
  <a href="https://moon.ankio.net/manual"><strong>用户手册</strong></a> ·
  <a href="https://moon.ankio.net/faq"><strong>常见问题</strong></a> ·
  <a href="https://moon.ankio.net/develop"><strong>开发文档</strong></a>
</p>

<p align="center">
  <img src="screenshots/home.png" width="48%" alt="月读首页">
  <img src="screenshots/reader.png" width="48%" alt="阅读页">
</p>

月读是装在 [KOReader](https://koreader.rocks/) 上的阅读插件。它不替换阅读器，而是补上书房桌面：多来源的书放进同一个书架，进度和笔记先记在本机，有网再同步。

按钮怎么点、每一项设置在哪，都写在官网，配了截图，照着做就行：

**[打开月读文档 moon.ankio.net](https://moon.ankio.net)**

## 它能做什么

| | |
|---|---|
| 书库 | 首页、图书馆、书城、订阅。本地目录、WebDAV，以及微信读书等在线书源 |
| 阅读 | 快捷面板、上下栏、侧栏、划词查词、翻页动画、重新排版 |
| 辅助 | AI 解释、X-Ray、整书双语、段评、生僻字注音 |
| 设备 | 组合锁屏、中文输入法、局域网远程管理 |

每个功能的开关、默认值和操作步骤在[用户手册](https://moon.ankio.net/manual)。数据源各自能同步什么，见[数据源](https://moon.ankio.net/manual/sources)。

<p align="center">
  <img src="screenshots/library.png" width="32%" alt="图书馆">
  <img src="screenshots/detail.png" width="32%" alt="书籍详情">
  <img src="screenshots/stats_overview.png" width="32%" alt="阅读统计">
</p>

## 安装

需要 KOReader **2026.07** 或更高。Kindle 要先越狱并装好 KOReader，按[越狱指南](https://moon.ankio.net/jailbreak)做。

1. 从 [Releases](https://github.com/AnkioTomas/moon/releases/latest) 下载最新的 `book.koplugin-*.zip`，解压出 `book.koplugin` 文件夹。
2. 把它放进 KOReader 的 `plugins/`。文件夹名必须是 `book.koplugin`，不能改名，也不能多套一层。
3. 重启 KOReader，从菜单打开 **月读**。

各设备的 `plugins` 在哪、解压多套一层怎么办、怎么确认装上了，见[安装](https://moon.ankio.net/manual/start/install)。装好后按[快速开始](https://moon.ankio.net/manual/start/quickstart)导入本地书或登录一个书源。

之后升级：在月读里打开 **设置 → 我的设备**，点 **版本**。说明见[插件更新](https://moon.ankio.net/manual/device/update)。

> 功能还在改。升级前保留设备上的 `.moon/` 数据目录。微信读书要在 **设置 → 书库 → 账号 → 微信读书** 用墨水屏客户端协议重新扫一次码。

## 可选插件

这些不是月读本体，不装也能读书。装进同一个 `plugins/` 后，月读里会多出入口。

| 插件 | 做什么 |
|---|---|
| [翻页器](https://github.com/AnkioTomas/ko-pageturner) | 蓝牙翻页器的手势和想法选择 |
| [小黑屋](https://github.com/AnkioTomas/ko-adarkroom) | 《A Dark Room》中文移植 |
| [阿页的阁楼](https://github.com/AnkioTomas/ko-paper-sprite) | 书签纸灵 |
| [游戏合集](https://github.com/AnkioTomas/ko-games) | 22 个离线小游戏 |

怎么玩见[游戏](https://moon.ankio.net/manual/library/games)。

## 给开发者

交付物只有 `book.koplugin/`，没有构建步骤。测试：

```bash
./tests/run.sh
```

环境、模拟器、架构和怎么写书源，见[开发文档](https://moon.ankio.net/develop)。月读服务（网页书库）是另一个仓库：[AnkioTomas/book](https://github.com/AnkioTomas/book)。

## 许可证

[GNU GPLv3](LICENSE)。感谢 [LINUX DO](https://linux.do/) 社区。
