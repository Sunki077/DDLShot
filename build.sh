#!/bin/bash
# build.sh — 编译并打包 DDLShot.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DDLShot.app"

# ── Bundle ID ────────────────────────────────────────────────
# 每台机器 / 每个 fork 用自己的 id。优先级：
#   1) 环境变量 DDLSHOT_BUNDLE_ID
#   2) ~/.config/ddlshot/bundle_id
#   3) 默认 app.ddlshot.mac
# ⚠️ 换了 bundle id 就要重新授权一次 —— TCC 是按 bundle id 记录「提醒事项 / 屏幕录制」的。
DEFAULT_BUNDLE_ID="app.ddlshot.mac"

resolve_bundle_id() {
  if [ -n "${DDLSHOT_BUNDLE_ID:-}" ]; then
    echo "$DDLSHOT_BUNDLE_ID"; return 0
  fi
  local f="$HOME/.config/ddlshot/bundle_id"
  if [ -f "$f" ]; then
    local v
    v="$(tr -d '[:space:]' < "$f")"
    if [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  echo "$DEFAULT_BUNDLE_ID"
  return 0
}

# ── 签名证书指纹 ──────────────────────────────────────────────
# 优先级：DDLSHOT_CERT_SHA1 → ~/.config/ddlshot/signing/cert.sha1 → 空（退回 ad-hoc）
# ./Tools/make_signing_cert.sh 会把本机证书的 SHA-1 写进那个文件。
resolve_cert_sha1() {
  if [ -n "${DDLSHOT_CERT_SHA1:-}" ]; then
    echo "$DDLSHOT_CERT_SHA1"; return 0
  fi
  local f="$HOME/.config/ddlshot/signing/cert.sha1"
  if [ -f "$f" ]; then
    local v
    v="$(tr -d '[:space:]' < "$f")"
    if [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  echo ""
  return 0
}

BUNDLE_ID="$(resolve_bundle_id)"
CERT_SHA1="$(resolve_cert_sha1)"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
swiftc -O \
  -target arm64-apple-macosx14.0 \
  -Xcc -fmodule-map-file="$ROOT/Sources/CShim/module.modulemap" \
  -I "$ROOT/Sources/CShim" \
  "$ROOT/Sources/DDLShotKit.swift" \
  "$ROOT/Sources/LLMEngine.swift" \
  "$ROOT/Sources/CropMath.swift" \
  "$ROOT/Sources/RegionSelector.swift" \
  "$ROOT/Sources/HotKey.swift" \
  "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/DDLShot" \
  -framework Carbon \
  -framework ScreenCaptureKit

echo "==> 生成 App 图标"
# 用 SF Symbols 现画一张 .icns：仓库里只存源码，clone 下来就能复现同一张图标。
swiftc -O "$ROOT/Tools/make_icon.swift" -o "$ROOT/build/make_icon" 2>/dev/null
"$ROOT/build/make_icon" "$ROOT/Resources" | sed 's/^/    /'

echo "==> 写入 Info.plist 与抽取器脚本"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/ddlshot_llm.py" "$APP/Contents/Resources/ddlshot_llm.py"
chmod +x "$APP/Contents/Resources/ddlshot_llm.py"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "    图标已装入 bundle"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
echo "    Bundle ID: $BUNDLE_ID"
echo "$BUNDLE_ID" > "$ROOT/build/.bundle_id"

echo "==> 签名"
# 用固定的自签名证书签名：ad-hoc 签名的 designated requirement 是 cdhash，
# 每重编译一次就变一次，TCC 里那条授权记录会立刻失效 → 每次截屏都弹「想要录制屏幕」。
# 证书签名的 DR 绑定的是证书（certificate root = ...），重编译后不变，授权可以一直复用。
if [ -n "$CERT_SHA1" ]; then
  if codesign --force --sign "$CERT_SHA1" --timestamp=none "$APP" >/dev/null 2>&1; then
    echo "    已用固定证书签名（SHA-1 $CERT_SHA1 · DR 绑定证书，重编译不丢权限）"
  else
    echo "    ⚠️ 用证书签名失败（钥匙串里没有该证书或私钥不可用），退回 ad-hoc 签名"
    echo "       → 可以运行 ./Tools/make_signing_cert.sh 生成一张本机自签证书"
    echo "       → 当前状态下重编译后需要去 系统设置 → 隐私与安全性 → 录屏与系统音频 重新打开 DDLShot"
    codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
  fi
else
  echo "    ⚠️ 没有找到签名证书指纹，退回 ad-hoc 签名"
  echo "       → 先跑 ./Tools/make_signing_cert.sh 生成一张本机自签证书，之后重编译就不必再授权了"
  codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> 校验"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "    designated requirement: $(codesign -d -r- "$APP" 2>/dev/null | tail -1)"
"$APP/Contents/MacOS/DDLShot" --selftest | tail -2

echo "==> 坐标换算自检"
swiftc -target arm64-apple-macosx14.0 \
  "$ROOT/Sources/CropMath.swift" "$ROOT/Tools/test_crop/main.swift" \
  -o "$ROOT/build/test_crop" 2>/dev/null
"$ROOT/build/test_crop" | tail -1

echo "==> 热键键码自检"
swiftc -target arm64-apple-macosx14.0 \
  -Xcc -fmodule-map-file="$ROOT/Sources/CShim/module.modulemap" \
  -I "$ROOT/Sources/CShim" \
  "$ROOT/Tools/test_hotkey/main.swift" \
  -o "$ROOT/build/test_hotkey" -framework Carbon 2>/dev/null
"$ROOT/build/test_hotkey" | tail -1

echo
echo "构建完成：$APP"
