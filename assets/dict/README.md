中文词典资源

数据来源：http://download.huzheng.org/zh_CN/

构建 / 更新（仓库根目录执行，纯 Python 标准库）：

    python3 tools/build_dict.py

默认生成四个词典：

  - 牛津现代英汉双解词典
  - 新华字典
  - 现代汉语词典
  - 古汉语常用字字典

每个上游 tar.bz2 都按 15 MiB 切片，产物形如 `{id}.part.NNN`。原始压缩包不保留，
`manifest.json` 记录原始文件的大小、SHA-256，以及每个分片的大小和 SHA-256。
设备端按某个 `dictionaries[].parts` 顺序拼接即可恢复对应的 tar.bz2；切片是为了
遵循与拼音词库相同的单文件分发上限。

只更新一个词典时，例如：

    python3 tools/build_dict.py --dict xhzd
