#!/bin/bash
# make_release.sh — 导出一份干净的可发布快照并打包成 zip
#
# 做三件事：
#   1) 只复制源码与脚本，不带 build/、.git/、个人配置等
#   2) 扫描一遍还有没有个人痕迹（用户名、绝对路径），有就提醒
#   3) 打成 zip 并算出 SHA-256
#
# 用法：
#     ./Tools/make_release.sh [输出目录]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="DDLShot"
OUT="${1:-$ROOT/../dist}"
STAGE="$OUT/stage/$NAME"
ZIP="$OUT/${NAME}-mac-src.zip"

rm -rf "$OUT/stage"
mkdir -p "$STAGE"

echo "==> 1/3 导出干净源码快照"
rsync -a \
  --exclude='/.git/' \
  --exclude='/build/' \
  --exclude='/dist/' \
  --exclude='.DS_Store' \
  --exclude='_CGS*' \
  "$ROOT/" "$STAGE/"
# 顺带清掉 macOS 的资源分支垃圾文件
find "$STAGE" -name '._*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true
echo "    文件数：$(find "$STAGE" -type f | wc -l | tr -d ' ')"

echo "==> 2/3 扫描个人痕迹"
FOUND=0
if grep -rn -I \
    -e '/Users/' \
    -e "$HOME" \
    -e 'sunki' \
    --include='*.swift' --include='*.py' --include='*.h' --include='*.sh' \
    --include='*.plist' --include='*.json' --include='*.md' \
    "$STAGE" 2>/dev/null | grep -v "Tools/make_release.sh" | head -20; then
  FOUND=1
fi
if [ "$FOUND" = "1" ]; then
  echo "    ⚠️ 上面这些位置还留着个人路径，发之前建议再扫一遍"
else
  echo "    干净，没有个人路径"
fi

echo "==> 3/3 打包"
cd "$OUT/stage"
rm -f "$ZIP"
zip -q -r -X "$ZIP" "$NAME"
cd "$ROOT"

SIZE=$(wc -c < "$ZIP" | tr -d ' ')
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

cat <<TXT

发布包已生成：
    文件   : $ZIP
    大小   : $SIZE 字节
    SHA-256: $SHA

包内只有源码与脚本，不含任何编译产物、证书、私钥或个人配置。
收件人解压后执行：
    ./Tools/make_signing_cert.sh     # 为他自己那台机器生成签名证书
    ./build.sh && ./install.sh
TXT
