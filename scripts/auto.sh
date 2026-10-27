#!/bin/bash

set -euo pipefail

OPENWRT_DIR="${1:-.}"
REPO="https://github.com/VIKINGYFY/immortalwrt.git"

[[ -d "$OPENWRT_DIR" ]] || { echo "错误: 目录不存在: $OPENWRT_DIR" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

git clone --depth 1 --branch owrt --filter=blob:none --sparse "$REPO" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"
git sparse-checkout set package/emortal

mkdir -p "$OPENWRT_DIR/package/emortal"
cp -a package/emortal/. "$OPENWRT_DIR/package/emortal/"

echo "完成, package/emortal 内容:"
ls -1 "$OPENWRT_DIR/package/emortal/"

echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
