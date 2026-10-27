#!/bin/bash
# 1. 下载 VIKINGYFY/immortalwrt (owrt分支) 的 package/emortal 整个目录到 OpenWRT 源码
# 2. 替换 feeds.conf.default 中的 packages 和 luci feed 为 immortalwrt 镜像

OPENWRT_DIR="${1:-.}"
REPO="https://github.com/VIKINGYFY/immortalwrt.git"

TMP_DIR=$(mktemp -d)
git clone --depth 1 --branch owrt --filter=blob:none --sparse "$REPO" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"
git sparse-checkout set package/emortal

mkdir -p "$OPENWRT_DIR/package/emortal"
cp -a package/emortal/* "$OPENWRT_DIR/package/emortal/"
rm -rf "$TMP_DIR"

# 替换 feeds 源为 immortalwrt 的 GitHub 镜像
sed -i \
    -e 's|^src-git packages .*|src-git packages https://github.com/immortalwrt/packages.git|' \
    -e 's|^src-git luci .*|src-git luci https://github.com/immortalwrt/luci.git|' \
    "$OPENWRT_DIR/feeds.conf.default"

echo "完成, package/emortal 内容:"
ls -1 "$OPENWRT_DIR/package/emortal/"
echo "feeds.conf.default:"
cat "$OPENWRT_DIR/feeds.conf.default"
