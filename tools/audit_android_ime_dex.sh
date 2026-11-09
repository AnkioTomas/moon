#!/usr/bin/env bash
# 审计 Android IME dex 的 API 面：只允许插件真正需要的那一小撮类型。
#
# 用法：
#   tools/audit_android_ime_dex.sh [DEX]        # 默认审计 features/system_ime/classes.dex
#   tools/audit_android_ime_dex.sh --dump DUMP  # 审计已生成的 dexdump -d 文本（无需 SDK）
#
# 判定：
#   1) 黑名单：java.net / Runtime.exec / 反射 / System.load* / 动态类加载；
#   2) 白名单：出现的每个 L...; 类型必须落在允许的包前缀内。
# 退出码：0 = 通过，1 = 命中禁用 API，2 = 用法 / 输入 / dexdump 错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_DEX="$ROOT/book.koplugin/features/system_ime/classes.dex"
PINS="build-tools 36.1.0 / platform android-36"

MODE="dex"
INPUT=""

usage() {
    cat <<EOF
Usage: tools/audit_android_ime_dex.sh [DEX]
       tools/audit_android_ime_dex.sh --dump DUMP

  DEX         要审计的 dex（默认 $DEFAULT_DEX）
  --dump      输入是 dexdump -d 的文本输出，不调用 dexdump（CI 逻辑测试 / 无 SDK 环境）
  -h, --help  显示本帮助

dexdump 查找顺序：\$DEXDUMP → PATH → \$ANDROID_HOME/$PINS/dexdump。
EOF
}

die() {
    echo "[audit] ERROR: $*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dump)
            MODE="dump"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if [ "$#" -gt 0 ]; then
                INPUT="$1"
                shift
            fi
            ;;
        -*)
            echo "[audit] ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            INPUT="$1"
            shift
            ;;
    esac
done

if [ -z "$INPUT" ]; then
    if [ "$MODE" = "dump" ]; then
        die "missing dump path after --dump"
    fi
    INPUT="$DEFAULT_DEX"
fi

[ -f "$INPUT" ] || die "input not found: $INPUT"
[ -r "$INPUT" ] || die "input not readable: $INPUT"
[ -s "$INPUT" ] || die "input is empty: $INPUT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$MODE" = "dump" ]; then
    DUMP="$INPUT"
else
    # dex 魔数 "dex\n"（6465780a）：防止把别的文件喂给 dexdump 后误判通过。
    MAGIC="$(LC_ALL=C head -c 4 "$INPUT" | od -An -tx1 | tr -d ' \n')"
    [ "$MAGIC" = "6465780a" ] || die "not a dex file (bad magic): $INPUT"

    DEXDUMP="${DEXDUMP:-}"
    if [ -z "$DEXDUMP" ]; then
        if command -v dexdump >/dev/null 2>&1; then
            DEXDUMP="$(command -v dexdump)"
        else
            SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
            if [ -n "$SDK" ] && [ -x "$SDK/build-tools/36.1.0/dexdump" ]; then
                DEXDUMP="$SDK/build-tools/36.1.0/dexdump"
            fi
        fi
    fi
    if [ -z "$DEXDUMP" ] || [ ! -x "$DEXDUMP" ]; then
        die "dexdump not found. Set ANDROID_HOME (needs $PINS) or DEXDUMP, or use --dump for text fixtures."
    fi

    DUMP="$TMP/dexdump.txt"
    if ! "$DEXDUMP" -d "$INPUT" >"$DUMP" 2>"$TMP/dexdump.err"; then
        sed 's/^/[audit] dexdump: /' "$TMP/dexdump.err" >&2 || true
        die "dexdump failed on $INPUT"
    fi
    [ -s "$DUMP" ] || die "dexdump produced no output for $INPUT"
fi

violations=0

# 黑名单：出现即违规。先跑黑名单，避免被白名单的 java/lang 前缀掩盖。
check_blacklist() {
    local label="$1" pattern="$2"
    if grep -Eq -- "$pattern" "$DUMP"; then
        echo "[audit] VIOLATION: $label" >&2
        grep -En -- "$pattern" "$DUMP" | head -n 3 | sed 's/^/[audit]   /' >&2 || true
        violations=$((violations + 1))
    fi
}

check_blacklist "java.net / javax.net" 'L(java|javax)/net/'
check_blacklist "Runtime.exec / ProcessBuilder" 'Ljava/lang/(Runtime|ProcessBuilder);'
check_blacklist "reflection (java.lang.reflect)" 'Ljava/lang/reflect/'
check_blacklist "reflection (Class.forName)" 'Ljava/lang/Class;(->|\.)forName'
check_blacklist "reflection (Class.getMethod/getDeclared*/newInstance)" \
    'Ljava/lang/Class;(->|\.)(getMethod|getDeclared(Method|Field|Constructor)|newInstance)'
check_blacklist "reflection (java.lang.invoke)" 'Ljava/lang/invoke/'
check_blacklist "System.load / System.loadLibrary" 'Ljava/lang/System;(->|\.)load'
check_blacklist "dynamic class loading" \
    'L(java/lang/ClassLoader|dalvik/system/(Dex|Path)ClassLoader);'

# 白名单：dex 里出现的每个类描述符都必须在此列内。
grep -oE 'L[A-Za-z0-9_$/]+;' "$DUMP" | sed 's/^L//; s/;$//' | sort -u >"$TMP/classes.txt" || true

CLASS_COUNT="$(wc -l <"$TMP/classes.txt" | tr -d ' ')"
if [ "$CLASS_COUNT" -eq 0 ]; then
    die "no class descriptors found in $INPUT (not dexdump output?)"
fi

while IFS= read -r cls; do
    [ -n "$cls" ] || continue
    case "$cls" in
        org/koreader/koboard/*|\
        android/app/*|\
        android/content/*|\
        android/graphics/*|\
        android/text/*|\
        android/util/*|\
        android/view/*|\
        android/widget/*|\
        dalvik/annotation/*|\
        java/io/*|\
        java/lang/*|\
        java/nio/charset/*)
            ;;
        *)
            echo "[audit] VIOLATION: type outside whitelist: L$cls;" >&2
            violations=$((violations + 1))
            ;;
    esac
done <"$TMP/classes.txt"

if [ "$violations" -gt 0 ]; then
    echo "[audit] FAILED: $violations violation(s) in $INPUT" >&2
    exit 1
fi

echo "[audit] OK: $CLASS_COUNT class(es), no forbidden APIs, all types whitelisted"
echo "[audit] input: $INPUT"
