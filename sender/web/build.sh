#!/bin/sh
# QrDrop Web 发送端构建：三个源文件压缩并拼接成单个 dist/vd.min.js
#
# 用法：sh build.sh
# 依赖：node + npx（首次运行会由 npx 拉取 esbuild）
#
# 不使用 esbuild --bundle：vd-protocol.js / vd-qr.js 是 UMD 包裹，
# bundle 会改写 typeof module 检测，破坏 test/run-vectors.js 的 require。
# 这里只做单文件压缩，再按依赖顺序拼接。

set -e
cd "$(dirname "$0")"

SRC="vd-protocol.js vd-qr.js vd-app.js"
OUT="dist"
TMP="$OUT/.tmp"

rm -rf "$OUT"
mkdir -p "$TMP"

# 逐文件压缩（保留各自的 IIFE 边界）
npx --yes esbuild $SRC --minify --outdir="$TMP" --log-level=warning

# 按依赖顺序拼接：protocol -> qr -> app
: > "$OUT/vd.min.js"
for f in $SRC; do
    cat "$TMP/$f" >> "$OUT/vd.min.js"
    echo "" >> "$OUT/vd.min.js"
done

# 语法自检
node --check "$OUT/vd.min.js"

# 生成 dist/index.html：三个 script 标签折叠成一个
perl -0pe 's{<script src="vd-protocol\.js"></script>\n<script src="vd-qr\.js"></script>\n<script src="vd-app\.js"></script>}{<script src="vd.min.js"></script>}' \
    index.html > "$OUT/index.html"

grep -q 'vd.min.js' "$OUT/index.html" || { echo "错误：index.html 的 script 标签未被替换"; exit 1; }

rm -rf "$TMP"

echo "构建完成："
for f in $SRC; do
    printf '  %-16s %6d B\n' "$f" "$(wc -c < "$f")"
done
printf '  %-16s %6d B  (gzip %d B)\n' "dist/vd.min.js" \
    "$(wc -c < "$OUT/vd.min.js")" "$(gzip -c "$OUT/vd.min.js" | wc -c)"
