# koboard（Android 系统输入法桥）

`classes.dex` 从 [titandrive/koboard](https://github.com/titandrive/koboard) v0.6.5
的 Java 源码可复现构建，用于在 Android 上提供一个带 `InputConnection` 的
`View`，把系统输入法上屏的文本通过文件快照交给 Lua。

- 上游仓库：<https://github.com/titandrive/koboard>
- Tag：`v0.6.5`（annotated tag `a9bd96d7f2bd5d64ab7e553f804b8e9925028002`）
- Commit：`d49f0981cdafd8a3e387a7f9e6be5d45f88cea08`
- 许可：MIT（见本目录 `LICENSE`、`THIRD_PARTY.txt`）
- Vendored：2026-11-09

## 文件映射

| 上游路径 | 本目录 |
| --- | --- |
| `android_src/org/koreader/koboard/KOBoardIC.java` | `java/android_src/org/koreader/koboard/KOBoardIC.java` |
| `android_src/org/koreader/koboard/KOBoardShow.java` | `java/android_src/org/koreader/koboard/KOBoardShow.java` |
| `android_src/org/koreader/koboard/KOBoardView.java` | `java/android_src/org/koreader/koboard/KOBoardView.java` |
| `scripts/build_dex.sh` | `java/scripts/build_dex.sh` |
| `README.md` | `java/README.md` |
| `RELEASE_NOTES_v0.6.5.md` | `java/RELEASE_NOTES_v0.6.5.md` |

上游在 v0.6.5 没有单独的 `LICENSE` 文件，只在 README 中声明 MIT；
本目录的 `LICENSE` 与 `THIRD_PARTY.txt` 保留该 MIT 声明。

**本地未做任何源码修改。** 上游 `scripts/build_dex.sh` 仅作参考；正式构建走
仓库根的 `tools/build_android_ime_dex.sh`（固定 JDK 21、Android build-tools
36.1.0、platform android-36，保留 `javac -source 8 -target 8` 与
`d8 --min-api 1`），产物哈希见 `../classes.dex.sha256`。

## 原始文件哈希

```
c78c88d449429f59c8020acaeaf306d10cbebe924ddad3c9cf1aadf277fa0760  android_src/org/koreader/koboard/KOBoardIC.java
6100903896d65ea102701ae75ac5e3daa5af3fd523c32e00ee512ddac0140e09  android_src/org/koreader/koboard/KOBoardShow.java
efbd7fd8a02f52f41ed1b078b6e8ed0effa0cd94b5e2a5dbb7f4e61ce88f42ad  android_src/org/koreader/koboard/KOBoardView.java
f417f8be93d1fe55623a142eb0bfb9d9d4a4533a2670e1e0dd426185a7c7603e  scripts/build_dex.sh
19b5940e786a46670d7defc05a4710868e80d4cdeb698364d1f257adac94da77  README.md
759a582543665f010c8ae365c72ec937cc68ebfe912202cb44f3f32d96fc9940  RELEASE_NOTES_v0.6.5.md
```
