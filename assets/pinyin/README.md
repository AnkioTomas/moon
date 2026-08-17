拼音词库

数据来源：https://github.com/iDvel/rime-ice （雾凇拼音，cn_dicts/ 下 5 个启用词库）

产物：

  manifest.json                 { tag, built_at, entries, raw_sha256, raw_size, parts }
  dictionary.sqlite3.gz.NNN     每片独立 gzip，按序 inflate 解压拼出原始 sqlite

生成 / 更新（仓库根，纯 stdlib Python）：

  python3 tools/build_pinyin_dict.py

设备端不读这里的文件——插件（pinyin/download.lua）经 jsdelivr 按
仓库 main 拉取切片、校验 raw_sha256、解压拼接成
$DATA/.moon/dictionary.sqlite3。切片是因为整库 gzip 后超 jsdelivr
~20MB 单文件上限。

schema（解压后的 sqlite）：

  meta(k PRIMARY KEY, v)            -- source_tag / built_at / entries
  words(word, pinyin, weight)       -- pinyin 无声调、空格分隔音节（"ni hao"）
  INDEX idx_pinyin(pinyin, weight DESC)
