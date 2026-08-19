拼音词库

数据来源：https://github.com/iDvel/rime-ice （雾凇拼音，cn_dicts/ 下 5 个启用词库）

产物：

  manifest.json                 { tag, built_at, entries, raw_sha256, raw_size, parts }
  dictionary.sqlite3.part.NNN   原始 SQLite 二进制分片，按序拼出原始 sqlite

生成 / 更新（仓库根，纯 stdlib Python）：

  python3 tools/build_pinyin_dict.py

设备端不读这里的文件——插件（pinyin/download.lua）经 jsdelivr 按
仓库 main 拉取切片、逐片校验 SHA-256 后拼接成
$DATA/.moon/dictionary.sqlite3。切片是因为单片超 jsdelivr
~20MB 单文件上限。

schema（解压后的 sqlite）：

  meta(k PRIMARY KEY, v)                    -- schema_version / source_tag / built_at / entries
  words(word, code, initials, weight)       -- code="nihao"，initials="nh"
  quick(mode, code, rank, word_id)          -- 高频短码的构建期 Top 21
  INDEX idx_code(code, weight DESC)
  INDEX idx_initials(initials, weight DESC)

运行时先用 quick 的主键等值查询：直接拼音 3-6 位、简拼 2-5 位都不排序。
简拼是每个音节的首字母，例如 `jfyhdcm` 对应「江枫渔火对愁眠」。
超过该范围才用 words 的前缀索引；此时候选集合已经很小。quick 只存 words 的
rowid，避免为每个短码重复保存 UTF-8 词文本。
