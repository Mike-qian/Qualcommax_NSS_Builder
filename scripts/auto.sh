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

# --- 首次开机修正 distfeeds.list (uci-defaults) ---
# 1. 删掉 kiddin9 行: 自定义 feed 会被构建系统写进设备上的
# 2. 官方源替换为清华镜像 (TUNA), 加速设备端 apk 下载。
mkdir -p "$OPENWRT_DIR/files/etc/uci-defaults"
cat > "$OPENWRT_DIR/files/etc/uci-defaults/998-fix-distfeeds" << 'EOF'
sed -i '\|kiddin9/op-packages|d' /etc/apk/repositories.d/distfeeds.list
sed -i 's|https://downloads.openwrt.org|https://mirrors.tuna.tsinghua.edu.cn/openwrt|g' /etc/apk/repositories.d/distfeeds.list
EOF
echo
echo "已写入 files/etc/uci-defaults/998-fix-distfeeds:"
cat "$OPENWRT_DIR/files/etc/uci-defaults/998-fix-distfeeds"

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
