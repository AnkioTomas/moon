#!/usr/bin/env bash
# 审计脚本决策逻辑回归（不需要 Android SDK / dexdump）。
# 用法：tests/tools/audit_android_ime_dex_spec.sh
#
# 审计脚本吃的是 `dexdump -d` 的文本输出（或等价的类/方法描述符文本）。
# 这里用合成 fixture 覆盖白名单与各类黑名单，验证退出码：
#   0 = 通过；1 = 命中禁用 API；2 = 用法 / 输入 / 工具错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="$ROOT/tools/audit_android_ime_dex.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

expect() {
    local name="$1" want="$2" file="$3"
    local out="$TMP/out.$pass.$RANDOM"
    local status=0
    set +e
    "$AUDIT" --dump "$file" >"$out" 2>&1
    status=$?
    set -e
    if [ "$status" -eq "$want" ]; then
        echo "ok - $name"
        pass=$((pass + 1))
    else
        echo "not ok - $name (exit $status, want $want)"
        sed 's/^/  /' "$out"
        fail=$((fail + 1))
    fi
}

# 与正式 dex 同形的允许 API：自有类 + android/ + java/io + java/lang + java/nio/charset + dalvik/annotation。
cat > "$TMP/allow.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  type          : 'Landroid/view/inputmethod/BaseInputConnection;'
  type          : 'Landroid/text/Editable;'
  type          : 'Ljava/io/FileWriter;'
  type          : 'Ljava/lang/String;'
  type          : 'Ljava/nio/charset/StandardCharsets;'
  type          : 'Ldalvik/annotation/Signature;'
EOF

cat > "$TMP/java-net.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-static {}, Ljava/net/URL;.openConnection:()Ljava/net/URLConnection;
EOF

cat > "$TMP/runtime-exec.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-virtual {v0, v1}, Ljava/lang/Runtime;.exec:(Ljava/lang/String;)Ljava/lang/Process;
EOF

cat > "$TMP/reflection.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-virtual {v0, v1}, Ljava/lang/Class;.getDeclaredMethod:(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
EOF

cat > "$TMP/for-name.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-static {v0}, Ljava/lang/Class;.forName:(Ljava/lang/String;)Ljava/lang/Class;
EOF

cat > "$TMP/system-load.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-static {v0}, Ljava/lang/System;.loadLibrary:(Ljava/lang/String;)V
EOF

cat > "$TMP/system-load-plain.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  0001: invoke-static {v0}, Ljava/lang/System;.load:(Ljava/lang/String;)V
EOF

cat > "$TMP/unknown-api.dump" <<'EOF'
Class descriptor  : 'Lorg/koreader/koboard/KOBoardIC;'
  type          : 'Lokhttp3/OkHttpClient;'
EOF

cat > "$TMP/empty.dump" <<'EOF'
no class descriptors here
EOF

expect "允许的 API 通过" 0 "$TMP/allow.dump"
expect "拒绝 java.net" 1 "$TMP/java-net.dump"
expect "拒绝 Runtime.exec" 1 "$TMP/runtime-exec.dump"
expect "拒绝反射 getDeclaredMethod" 1 "$TMP/reflection.dump"
expect "拒绝 Class.forName" 1 "$TMP/for-name.dump"
expect "拒绝 System.loadLibrary" 1 "$TMP/system-load.dump"
expect "拒绝 System.load" 1 "$TMP/system-load-plain.dump"
expect "拒绝白名单外的 API" 1 "$TMP/unknown-api.dump"
expect "空 / 非 dexdump 文本按输入错误处理" 2 "$TMP/empty.dump"

# 缺文件
set +e
"$AUDIT" --dump "$TMP/does-not-exist.dump" >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 2 ]; then
    echo "ok - 缺文件返回 2"
    pass=$((pass + 1))
else
    echo "not ok - 缺文件返回 $status，期望 2"
    fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
