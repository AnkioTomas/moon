中文词典资源

数据来源：http://download.huzheng.org/

构建 / 更新（仓库根目录执行，纯 Python 标准库）：

    python3 tools/build_dict.py

默认按语言收录阅读器常用词典（专业/考试/宗教/重复美化版不进清单）：

  简体中文
    - 牛津现代英汉双解词典
    - 朗道英汉字典 / 朗道汉英字典
    - 新华字典 / 现代汉语词典 / 古汉语常用字字典
    - 中华成语大词典 / 高级汉语大词典
    - CC-CEDICT 汉英词典 / 康熙字典（文字版）

  英语
    - WordNet
    - Webster's Revised Unabridged Dictionary (1913)

  日语
    - 日汉双解词典
    - JMDict 日英词典

  韩语
    - Naver 韩中 / 中韩词典

  德语 / 法语 / 俄语
    - 新德汉词典
    - 法汉汉法词典
    - 一典通俄汉词典

每个上游 tar.bz2 都按 15 MiB 切片，产物形如 `{id}.part.NNN`。原始压缩包不保留，
`manifest.json` 记录语言分组、原始文件大小/SHA-256，以及每个分片的大小和 SHA-256。
设备端先按 `languages` / `dictionaries[].lang` 分组展示，再按某个 `parts` 顺序拼接恢复 tar.bz2。

只更新一个词典时，例如：

    python3 tools/build_dict.py --dict langdao-ec
