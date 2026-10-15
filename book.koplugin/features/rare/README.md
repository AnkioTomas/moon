# 生僻字注音（features/rare）

阅读页在生僻字 / 生词上方画拼音或音标，只画不改书。挂在 `reader/page_marks.lua` 的绘制层（图层 `paint`），
仅滚动排版（EPUB 等 CRE 文档）生效。

- `lexicon.lua`：词库解析、阈值匹配、英文切词与词形还原（纯函数）
- `overlay.lua`：取屏上文字 → 匹配 → `findText` 取框 → 布局绘制；按视口缓存，单屏取框预算 250ms
- `catalog.lua`：词库清单、下载（复用 `features.ime.download.install`）、启用、删除
- `setting.lua`：设置页「阅读 → 生僻字注音」

## 词库托管

与输入法词库相同：仓库 `assets/rare/<id>/manifest.json` + `lexicon.tsv.part.NNN`，设备经
`https://cdn.jsdelivr.net/gh/AnkioTomas/moon@main/assets/rare/<id>/` 拉取，sha256 校验后落到
`$DATA/.moon/rare/<id>.tsv`。下载失败不影响阅读，只是没有注音。

## 词库格式

UTF-8 文本，`#key=value` 元信息行 + 每行一条 `键<TAB>注音<TAB>rank`：

```
#name=汉字拼音
#lang=zh
#version=2026.10.15
#license=MIT
#levels=6500,3500,0
龘	dá	9000
一曏	yī xiàng	9000
```

- `lang`：`zh` 逐字匹配，多字键按最长匹配（用于多音字词组）；`en` 按连续字母切词、忽略大小写，
  查不到时依次试去掉 `s / es / ies→y / ed / ing` 的词形。
- `rank`：越大越生僻（汉字用《通用规范汉字表》序号，表外字 9000；英文用词频排名）。
- `levels`：「最生僻 / 生僻 / 全部」三档阈值，rank **大于**阈值才注音。缺省 zh `6500,3500,0`、en `20000,8000,0`。

自制词库：同格式存为 `$DATA/.moon/rare/<id>.tsv`（id 只含字母数字 `_-`），设置页会列出，点开启用。
