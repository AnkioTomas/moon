文字识别（OCR）模型

数据来源：https://github.com/tesseract-ocr/tessdata_fast
许可证：Apache License 2.0（见同目录 LICENSE），版权归 Google / Tesseract 贡献者所有，本目录原样再分发，未做修改。

收录 LSTM fast 版（体积最小，兼容 KOReader 内置的 Tesseract 4.x / 5.x）：
简体中文、繁体中文、英语、日语、简体中文（竖排）、繁体中文（竖排）。

构建 / 更新（仓库根目录执行，纯 Python 标准库）：

    python3 tools/build_ocr_manifest.py           # 只为已有文件重算 manifest.json
    python3 tools/build_ocr_manifest.py --fetch   # 重新从上游下载再生成

`manifest.json` 记录每个模型的文件名、大小与 SHA-256；设备端（features/ocr）下载到
KOReader 的 data/tessdata，校验通过后原子改名到位。
