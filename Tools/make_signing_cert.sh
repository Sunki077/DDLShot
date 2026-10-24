#!/bin/bash
# make_signing_cert.sh — 给「这台机器」生成一张专用于代码签名的自签名证书
#
# 为什么需要它
# ------------
# macOS 对 ad-hoc 签名的 app，designated requirement 只能是 cdhash。
# 代码一改 cdhash 就变 → TCC 里那条「屏幕录制 / 提醒事项」授权记录随即失效，
# 每次截屏都要重新授权一次（就是那个「明明开了还是弹窗」的最终根因）。
#
# 证书签名的 DR 绑定的是证书本身：
#     designated => identifier "app.ddlshot.mac" and certificate root = H"…"
# 重编译后 cdhash 变了，但这行 DR 一模一样 → TCC 直接复用旧授权，再也不弹。
#
# 用法
# ----
#     ./Tools/make_signing_cert.sh
#
# 幂等：钥匙串里已经有同名证书时**直接复用、不重新生成**。
# （重新生成会换掉 DR，从而打断你已有的 TCC 授权记录，得重新授权一次。）
#
# 产物
# ----
#     ~/.config/ddlshot/signing/ddlshot.key   私钥（600）
#     ~/.config/ddlshot/signing/ddlshot.crt   证书
#     ~/.config/ddlshot/signing/ddlshot.p12   PKCS#12（600）
#     ~/.config/ddlshot/signing/cert.sha1     证书指纹 → build.sh 自动读取
set -euo pipefail

CERT_DIR="${DDLSHOT_CERT_DIR:-$HOME/.config/ddlshot/signing}"
CERT_NAME="${DDLSHOT_CERT_NAME:-DDLShot Code Signing}"
KEYCHAIN="${DDLSHOT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASS="${DDLSHOT_P12_PASS:-ddlshotlocal}"
SHA1_FILE="$CERT_DIR/cert.sha1"

for c in openssl security; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c，无法生成签名证书" >&2; exit 1; }
done

case "$CERT_NAME" in
  */*) echo "证书名不能包含 '/'：$CERT_NAME" >&2; exit 1 ;;
esac

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# 从钥匙串里查同名证书的 SHA-1 指纹
find_sha1() {
  security find-certificate -c "$CERT_NAME" -a -Z "$KEYCHAIN" 2>/dev/null \
    | grep -a "SHA-1 hash" | head -1 | awk '{print $3}'
}

SHA1="$(find_sha1 || true)"

if [ -n "$SHA1" ]; then
  echo "==> 钥匙串里已有证书「$CERT_NAME」，直接复用（不重新生成，避免打断已有授权）"
  echo "$SHA1" > "$SHA1_FILE"
  echo "    SHA-1 : $SHA1"
  echo "    已写入 $SHA1_FILE"
  echo "    build.sh 会自动读取这个指纹来签名，重编译不丢权限。"
  exit 0
fi

echo "==> 1/4 生成自签名证书"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 用配置文件而不是 -addext，兼容 LibreSSL 与 OpenSSL 3
cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3_code
prompt             = no

[dn]
CN = $CERT_NAME

[v3_code]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/ddlshot.key" \
  -out    "$CERT_DIR/ddlshot.crt" \
  -days 3650 \
  -config "$TMP/openssl.cnf" 2>/dev/null
chmod 600 "$CERT_DIR/ddlshot.key"

echo "==> 2/4 导出 PKCS#12"
# OpenSSL 3 的新算法 macOS 解析不了，必须用 -legacy；LibreSSL 没有这个参数
if ! openssl pkcs12 -export -legacy \
      -out "$CERT_DIR/ddlshot.p12" \
      -inkey "$CERT_DIR/ddlshot.key" -in "$CERT_DIR/ddlshot.crt" \
      -passout "pass:$P12_PASS" -name "$CERT_NAME" 2>/dev/null; then
  openssl pkcs12 -export \
    -out "$CERT_DIR/ddlshot.p12" \
    -inkey "$CERT_DIR/ddlshot.key" -in "$CERT_DIR/ddlshot.crt" \
    -passout "pass:$P12_PASS" -name "$CERT_NAME"
fi
chmod 600 "$CERT_DIR/ddlshot.p12"

echo "==> 3/4 导入登录钥匙串"
# -A：允许任意程序访问这把私钥，避免每次 codesign 都弹钥匙串授权框
security import "$CERT_DIR/ddlshot.p12" \
  -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A >/dev/null

echo "==> 4/4 自检"
CERT_MOD="$(openssl x509 -noout -modulus -in "$CERT_DIR/ddlshot.crt" | openssl sha256 | awk '{print $2}')"
KEY_MOD="$(openssl rsa  -noout -modulus -in "$CERT_DIR/ddlshot.key" 2>/dev/null | openssl sha256 | awk '{print $2}')"
if [ "$CERT_MOD" != "$KEY_MOD" ]; then
  echo "    ✗ 私钥与证书不匹配" >&2; exit 1
fi
echo "    私钥 ↔ 证书：匹配"
if openssl x509 -in "$CERT_DIR/ddlshot.crt" -noout -text | grep -q "Code Signing"; then
  echo "    用途：Code Signing ✅（缺这一项 macOS 不认它是代码签名身份）"
else
  echo "    ⚠️ 证书里没找到 codeSigning 用途" >&2
fi

SHA1="$(find_sha1 || true)"
if [ -z "$SHA1" ]; then
  echo "    ✗ 导入钥匙串后没查到证书指纹" >&2; exit 1
fi
echo "$SHA1" > "$SHA1_FILE"
echo "    SHA-1 : $SHA1"
echo "    已写入 $SHA1_FILE"

cat <<TXT

完成。下一步：

    ./build.sh && ./install.sh

build.sh 会自动读取 $SHA1_FILE 里的指纹来签名，
所以你以后重编译多少次，录屏 / 提醒事项权限都不会失效。

如果 codesign 第一次用这把钥匙时弹了钥匙串授权框，点「始终允许」即可。
TXT
