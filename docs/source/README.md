# source/ — 数据源

路径：[`book.koplugin/source/`](../../book.koplugin/source/)。

## 设计总览

数据源适配外部书库。查询默认读本地；远端只负责把变更写回 SQLite。  
新增源 = `source/<id>/init.lua` 门面（必需）+ 可选 `source/<id>/setting.lua`（设置入口）+ `registry` 注册。其余文件怎么拆由源自己决定，源外代码不依赖。

顶层禁止 require KOReader UI 模块（离线测试直接 load 源文件）；`NetworkMgr` / 弹窗等延迟到函数内。

| 文档 | 讲什么 |
|---|---|
| [`registry`](registry.md) | 活跃源、resolve、启用列表 |
| [`base`](base.md) | 基类契约、onEvent、默认本地查询 |
| [`chapter`](chapter.md) | 按章落盘 / 目录缓存 / 选章 / 预取 |
| [`sources`](sources.md) | 各已注册源的形态与能力 |
| [`external`](external.md) | 第三方书源：以独立 KOReader 插件发布 |

Z-Library 在 [`../zlib/`](../zlib/README.md)，不是 BookSource。
