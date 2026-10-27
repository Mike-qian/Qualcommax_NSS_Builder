#!/bin/bash
set -euo pipefail
OPENWRT_DIR="${1:-.}"
REPO="https://github.com/VIKINGYFY/immortalwrt.git"
OP_PKGS_REPO="https://github.com/kiddin9/op-packages.git"
[[ -d "$OPENWRT_DIR" ]] || { echo "错误: 目录不存在: $OPENWRT_DIR" >&2; exit 1; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$OPENWRT_DIR/package/emortal"

# --- emortal 包 ---
git clone --depth 1 --branch owrt --filter=blob:none --sparse "$REPO" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"
git sparse-checkout set package/emortal
cp -a package/emortal/. "$OPENWRT_DIR/package/emortal/"
echo "完成, emortal 包:"
ls -1 "$OPENWRT_DIR/package/emortal/"

# --- kiddin9/op-packages ---
git clone --depth 1 "$OP_PKGS_REPO" "$TMP_DIR/op-packages"
for dir in "$TMP_DIR/op-packages"/*/; do
    dir=${dir%/}
    [[ -f "$dir/Makefile" ]] || continue
    name=$(basename "$dir")
    cp -a "$dir" "$OPENWRT_DIR/package/emortal/$name"
done
echo
echo "完成, op-packages 拷入后 package/emortal 共 $(ls -1 "$OPENWRT_DIR/package/emortal/" | wc -l) 项"
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
