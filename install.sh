#!/bin/bash
# install.sh — 把 DDLShot.app 安装到 ~/Applications、注册开机自启并启动
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/DDLShot.app"
TARGET="$HOME/Applications/DDLShot.app"

# Bundle ID：优先用 build.sh 实际用的那个，保证安装的和编译出来的是同一个身份
DEFAULT_BUNDLE_ID="app.ddlshot.mac"
resolve_bundle_id() {
  if [ -f "$ROOT/build/.bundle_id" ]; then
    local v
    v="$(tr -d '[:space:]' < "$ROOT/build/.bundle_id")"
    if [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  if [ -n "${DDLSHOT_BUNDLE_ID:-}" ]; then echo "$DDLSHOT_BUNDLE_ID"; return 0; fi
  local f="$HOME/.config/ddlshot/bundle_id"
  if [ -f "$f" ]; then
    local v
    v="$(tr -d '[:space:]' < "$f")"
    if [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  echo "$DEFAULT_BUNDLE_ID"
  return 0
}

BUNDLE_ID="$(resolve_bundle_id)"
AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"

if [ ! -d "$SRC" ]; then
  echo "找不到 $SRC，请先运行 ./build.sh" >&2
  exit 1
fi

echo "==> 1/5 安装到 $TARGET"
mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$SRC" "$TARGET"            # ditto 比 cp -R 更完整地保留 app 结构与签名
codesign --verify "$TARGET" && echo "    签名校验通过"
echo "    Bundle ID: $BUNDLE_ID"
echo "    designated requirement: $(codesign -d -r- "$TARGET" 2>/dev/null | tail -1)"

echo "==> 2/5 注册开机自启（LaunchAgent）"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${BUNDLE_ID}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${TARGET}/Contents/MacOS/DDLShot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnvironmentVariables</key>
	<dict>
		<!-- 开机自启时不弹控制面板、不抢焦点 -->
		<key>DDLSHOT_LAUNCHED_AT_LOGIN</key>
		<string>1</string>
	</dict>
</dict>
</plist>
PLIST

# 换了 bundle id 的话，把旧 id 的自启项清掉，避免同时跑两个实例
for old in "$HOME/Library/LaunchAgents/"*.ddlshot.plist; do
  [ -e "$old" ] || continue
  if [ "$old" != "$AGENT" ]; then
    echo "    发现旧 bundle id 的自启项：$(basename "$old") → 卸载"
    launchctl unload "$old" 2>/dev/null || true
    rm -f "$old"
  fi
done

launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT" 2>/dev/null || true
echo "    已写入 ${AGENT}"
echo "    想取消开机自启：launchctl unload \"${AGENT}\" && rm \"${AGENT}\""

echo "==> 3/5 启动"
# 菜单栏 App 有单实例保护：老进程还活着时新实例会直接退出，
# 结果就是「装的是新代码、跑的却是老进程」。所以先明确停掉旧进程再拉起。
pkill -f "DDLShot.app/Contents/MacOS/DDLShot" 2>/dev/null || true
sleep 1
launchctl kickstart "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || open -a "$TARGET"
sleep 2
if pgrep -f "DDLShot.app/Contents/MacOS/DDLShot" >/dev/null 2>&1; then
  PID=$(pgrep -f "DDLShot.app/Contents/MacOS/DDLShot" | head -1)
  echo "    已启动（PID ${PID}，启动于 $(ps -o lstart= -p ${PID} | xargs)）"
else
  echo "    ⚠️ 未检测到进程，可用下面的命令手动看日志："
  echo "       log stream --predicate 'process == \"DDLShot\"' --style compact"
fi

echo "==> 4/5 准备大模型配置"
CFG_DIR="$HOME/.config/ddlshot"
CFG="$CFG_DIR/config.json"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG" ]; then
  cp "$ROOT/Resources/ddlshot-config.example.json" "$CFG"
  echo "    已生成配置模板：$CFG"
  echo "    填上 provider / base_url / api_key / model，大模型引擎即可用。"
  echo "    （不填也能用，DDLShot 会一直走本地规则引擎）"
else
  echo "    配置已存在：$CFG"
fi

echo "==> 5/5 记住本机 bundle id"
printf '%s' "$BUNDLE_ID" > "$CFG_DIR/bundle_id"
echo "    已写入 ${CFG_DIR}/bundle_id（下次 build.sh 会沿用这个 id，权限不用重新授权）"

cat <<TXT

权限（首次使用会弹窗，请点「允许」）：
    · 提醒事项：系统设置 → 隐私与安全性 → 提醒事项 → 打开 DDLShot
    · 录屏与系统录音：系统设置 → 隐私与安全性 → 录屏与系统录音 → 打开 DDLShot
      （macOS 14 及以前这项叫「屏幕录制」）
    · 辅助功能（可选）：系统设置 → 隐私与安全性 → 辅助功能 → 打开 DDLShot
      （不开也能用热键，只是热键改由系统「快捷指令」来触发更稳）

随时自检权限：
    ~/Applications/DDLShot.app/Contents/MacOS/DDLShot --status

签名用的是一张**固定的自签名证书**（指纹记录在 ~/.config/ddlshot/signing/cert.sha1），
所以 designated requirement 绑定的是证书而不是 cdhash ——
以后每次重新编译覆盖安装，录屏权限都**不会**失效，不需要再开一次开关。
（证书是每台机器自己生成的：./Tools/make_signing_cert.sh）

完成。用法：
    · 双击 ~/Applications/DDLShot.app → 打开「控制面板」，上面有三个按钮
      （截取最前窗口 / 手动框选区域 / 解析剪贴板文字）
    · 任何时候按 ⌃⌥D → 直接截取最前窗口并写入提醒事项
    · 菜单栏图标在这台 macOS 26 上可能不显示（系统不渲染第三方状态项），
      控制面板才是主入口，不影响使用
TXT
