#!/bin/bash
# 下载 VIKINGYFY/immortalwrt (owrt分支) 的 package/emortal 整个目录到 OpenWRT 源码

OPENWRT_DIR="${1:-.}"
REPO="https://github.com/VIKINGYFY/immortalwrt.git"

TMP_DIR=$(mktemp -d)
git clone --depth 1 --branch owrt --filter=blob:none --sparse "$REPO" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"
git sparse-checkout set package/emortal

mkdir -p "$OPENWRT_DIR/package/emortal"
cp -a package/emortal/* "$OPENWRT_DIR/package/emortal/"
rm -rf "$TMP_DIR"

echo "完成:"
ls -1 "$OPENWRT_DIR/package/emortal/"
