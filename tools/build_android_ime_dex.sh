#!/usr/bin/env bash
# 从 vendored koboard 源码可复现构建 Android IME dex，并对照提交的 sha256。
#
# 用法：tools/build_android_ime_dex.sh
#
# 固定工具链（改动会导致哈希漂移，必须先论证）：
#   JDK 21（$JAVA_HOME）
#   Android build-tools 36.1.0（$ANDROID_HOME/build-tools/36.1.0/d8）
#   Android platform android-36（$ANDROID_HOME/platforms/android-36/android.jar）
# 保留上游参数：javac -source 8 -target 8 -bootclasspath，d8 --min-api 1 --lib。
#
# 输出：book.koplugin/features/system_ime/classes.dex
#      仅当哈希与 classes.dex.sha256 一致时才落盘，避免把错误产物带进 release。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IME_DIR="$ROOT/book.koplugin/features/system_ime"
SRC_DIR="$IME_DIR/java/android_src/org/koreader/koboard"
CHECKSUM_FILE="$IME_DIR/classes.dex.sha256"
OUT_DEX="$IME_DIR/classes.dex"

PIN_JDK_MAJOR="21"
PIN_BUILD_TOOLS="36.1.0"
PIN_PLATFORM="android-36"

die() {
    echo "[android-ime] ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: tools/build_android_ime_dex.sh

Environment:
  JAVA_HOME     JDK ${PIN_JDK_MAJOR}（必须；脚本会校验 major 版本）
  ANDROID_HOME  Android SDK（或 ANDROID_SDK_ROOT），需含：
                  build-tools/${PIN_BUILD_TOOLS}/d8
                  platforms/${PIN_PLATFORM}/android.jar

Output:
  ${OUT_DEX}
  写入前对照 ${CHECKSUM_FILE}；不一致时退出 1 且不落盘。
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        die "unknown argument: $1"
        ;;
esac

# --- sha256 工具（Linux sha256sum / macOS shasum） -------------------------
if command -v sha256sum >/dev/null 2>&1; then
    hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    die "need sha256sum or shasum to verify the dex hash"
fi

# --- 校验输入 --------------------------------------------------------------
[ -f "$CHECKSUM_FILE" ] || die "missing committed checksum: $CHECKSUM_FILE"
EXPECTED="$(awk 'NF {print $1; exit}' "$CHECKSUM_FILE")"
case "$EXPECTED" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
        if [ "${#EXPECTED}" -ne 64 ]; then
            die "malformed sha256 in $CHECKSUM_FILE: $EXPECTED"
        fi
        ;;
    *)
        die "malformed sha256 in $CHECKSUM_FILE: ${EXPECTED:-<empty>}"
        ;;
esac

[ -d "$SRC_DIR" ] || die "vendored Java source missing: $SRC_DIR"
set -- "$SRC_DIR"/*.java
[ -f "$1" ] || die "no Java source found in $SRC_DIR"
JAVA_SOURCES=("$@")

# --- JDK 21 ----------------------------------------------------------------
[ -n "${JAVA_HOME:-}" ] || die "JAVA_HOME is not set; install JDK ${PIN_JDK_MAJOR} (e.g. Temurin 21) and export JAVA_HOME"
JAVAC="$JAVA_HOME/bin/javac"
[ -x "$JAVAC" ] || die "javac not found at $JAVAC; JAVA_HOME must point to a JDK (not a JRE)"

JAVAC_VERSION="$("$JAVAC" -version 2>&1 | awk '{print $2}')"
JAVAC_MAJOR="${JAVAC_VERSION%%.*}"
[ "$JAVAC_MAJOR" = "$PIN_JDK_MAJOR" ] || die "JDK ${PIN_JDK_MAJOR} required for a byte-identical dex, found javac ${JAVAC_VERSION:-unknown} (JAVA_HOME=$JAVA_HOME)"

# --- Android SDK -----------------------------------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] || die "ANDROID_HOME (or ANDROID_SDK_ROOT) is not set; need build-tools ${PIN_BUILD_TOOLS} and platforms/${PIN_PLATFORM}"
[ -d "$SDK" ] || die "Android SDK directory not found: $SDK"

ANDROID_JAR="$SDK/platforms/$PIN_PLATFORM/android.jar"
[ -f "$ANDROID_JAR" ] || die "missing platform jar: $ANDROID_JAR (install platforms;${PIN_PLATFORM} via sdkmanager)"

D8="$SDK/build-tools/$PIN_BUILD_TOOLS/d8"
[ -x "$D8" ] || die "missing d8: $D8 (install build-tools;${PIN_BUILD_TOOLS} via sdkmanager)"

# --- 构建 ------------------------------------------------------------------
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/moon-ime-dex.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

mkdir -p "$BUILD/classes" "$BUILD/dex"

echo "[android-ime] javac ${JAVAC_VERSION} (source/target 8)"
"$JAVAC" -source 8 -target 8 -bootclasspath "$ANDROID_JAR" \
    -d "$BUILD/classes" \
    "${JAVA_SOURCES[@]}"

CLASS_FILES=()
while IFS= read -r -d '' class_file; do
    CLASS_FILES+=("$class_file")
done < <(find "$BUILD/classes" -name '*.class' -print0)
[ "${#CLASS_FILES[@]}" -gt 0 ] || die "javac produced no .class files"

echo "[android-ime] d8 $(basename "$D8") --min-api 1"
JAVA_HOME="$JAVA_HOME" "$D8" --min-api 1 --lib "$ANDROID_JAR" \
    --output "$BUILD/dex" "${CLASS_FILES[@]}"

[ -f "$BUILD/dex/classes.dex" ] || die "d8 produced no classes.dex"
ACTUAL="$(hash_file "$BUILD/dex/classes.dex")"

if [ "$ACTUAL" != "$EXPECTED" ]; then
    {
        echo "[android-ime] ERROR: dex hash mismatch; refusing to write $OUT_DEX"
        echo "[android-ime]   expected: $EXPECTED"
        echo "[android-ime]   actual:   $ACTUAL"
        echo "[android-ime] pinned toolchain: JDK ${PIN_JDK_MAJOR}, build-tools ${PIN_BUILD_TOOLS}, platform ${PIN_PLATFORM}"
        echo "[android-ime] check for toolchain drift or local source edits before updating the checksum."
    } >&2
    exit 1
fi

cp "$BUILD/dex/classes.dex" "$OUT_DEX"
chmod 0644 "$OUT_DEX"

echo "[android-ime] wrote $OUT_DEX"
echo "[android-ime] sha256 $ACTUAL (matches classes.dex.sha256)"
