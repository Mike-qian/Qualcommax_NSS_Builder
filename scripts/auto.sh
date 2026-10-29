#!/bin/bash

set -euo pipefail
OPENWRT_DIR="${1:-.}"
REPO="https://github.com/VIKINGYFY/immortalwrt.git"
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

# --- kiddin9/op-packages 作为 feed 追加到 feeds.conf.default 末尾 ---
echo "src-git kiddin9 https://github.com/kiddin9/op-packages.git" >> "$OPENWRT_DIR/feeds.conf.default"
echo
echo "feeds.conf.default:"
cat "$OPENWRT_DIR/feeds.conf.default"

# --- 首次开机删掉 distfeeds.list 里的 kiddin9 行 (uci-defaults) ---
mkdir -p "$OPENWRT_DIR/files/etc/uci-defaults"
cat > "$OPENWRT_DIR/files/etc/uci-defaults/998-clean-distfeeds" << 'EOF'
[ -f /etc/apk/repositories.d/distfeeds.list ] && \
    sed -i -e '/kiddin9/d' -e '/mike-qian\.github\.io/d' /etc/apk/repositories.d/distfeeds.list
EOF
echo
echo "已写入 files/etc/uci-defaults/998-clean-distfeeds:"
cat "$OPENWRT_DIR/files/etc/uci-defaults/998-clean-distfeeds"

# --- 活动连接上限 65535 (uci-defaults) ---
mkdir -p "$OPENWRT_DIR/files/etc/uci-defaults"
cat > "$OPENWRT_DIR/files/etc/uci-defaults/999-conntrack-max" << 'EOF'
echo "net.netfilter.nf_conntrack_max=65535" > /etc/sysctl.d/99-conntrack-max.conf
echo "net.netfilter.nf_conntrack_buckets=16384" >> /etc/sysctl.d/99-conntrack-max.conf
sysctl -w -p /etc/sysctl.d/99-conntrack-max.conf
EOF
echo
echo "已写入 files/etc/uci-defaults/999-conntrack-max:"
cat "$OPENWRT_DIR/files/etc/uci-defaults/999-conntrack-max"
echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
