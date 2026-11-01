#!/bin/bash

set -euo pipefail

OPENWRT_DIR="${1:-.}"
[[ -d "$OPENWRT_DIR" ]] || { echo "错误: 目录不存在: $OPENWRT_DIR" >&2; exit 1; }
OPENWRT_DIR="$(cd "$OPENWRT_DIR" && pwd)"

REPO="https://github.com/VIKINGYFY/immortalwrt.git"
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

# --- kiddin9追加到 feeds.conf.default 末尾
KIDDIN9_LINE="src-git kiddin9 https://github.com/kiddin9/op-packages.git"
if ! grep -qxF "$KIDDIN9_LINE" "$OPENWRT_DIR/feeds.conf.default"; then
    echo "$KIDDIN9_LINE" >> "$OPENWRT_DIR/feeds.conf.default"
fi
echo
echo "feeds.conf.default:"
cat "$OPENWRT_DIR/feeds.conf.default"

# --- 首次开机: 把 mike-qian kmod feed 替换为官方 OpenWrt snapshots 软件包源 ---
UCI_DIR="$OPENWRT_DIR/files/etc/uci-defaults"
mkdir -p "$UCI_DIR"

cat > "$UCI_DIR/998-clean-distfeeds" << 'EOF'
#!/bin/sh
# 移除 kiddin9 feed, 并将任何包含 mike-qian 的软件源整行替换为官方 OpenWrt snapshots 软件包源。
# target/subtarget 从 /etc/openwrt_release 的 DISTRIB_TARGET 动态提取 (格式 qualcommax/ipq807x),
# 以适配不同设备 (ipq807x / ipq60xx 等); 取不到时回退到 qualcommax/ipq807x。
if [ -f /etc/apk/repositories.d/distfeeds.list ]; then
    TARGET="$(grep -m1 '^DISTRIB_TARGET=' /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)"
    [ -z "$TARGET" ] && TARGET="qualcommax/ipq807x"
    OFFICIAL="https://downloads.openwrt.org/snapshots/targets/${TARGET}/packages/packages.adb"
    sed -i -e '/kiddin9/d' \
      -e "s#^.*mike-qian\.github\.io.*#${OFFICIAL}#" \
      /etc/apk/repositories.d/distfeeds.list
fi
EOF
chmod +x "$UCI_DIR/998-clean-distfeeds"
echo
echo "已写入 files/etc/uci-defaults/998-clean-distfeeds:"
cat "$UCI_DIR/998-clean-distfeeds"

# --- 活动连接上限 65535 (uci-defaults) ---
cat > "$UCI_DIR/999-conntrack-max" << 'EOF'
#!/bin/sh
modprobe nf_conntrack 2>/dev/null || true
echo "net.netfilter.nf_conntrack_max=65535" > /etc/sysctl.d/99-conntrack-max.conf
sysctl -w net.netfilter.nf_conntrack_max=65535 2>/dev/null || true

if [ -d /etc/modprobe.d ]; then
    echo "options nf_conntrack hashsize=16384" > /etc/modprobe.d/nf_conntrack.conf
fi
EOF
chmod +x "$UCI_DIR/999-conntrack-max"
echo
echo "已写入 files/etc/uci-defaults/999-conntrack-max:"
cat "$UCI_DIR/999-conntrack-max"

# --- 首次开机: 时区、系统日志与 NTP 设置 ---
cat > "$UCI_DIR/996-tz-locale" << 'EOF'
#!/bin/sh
# 时区设为 Asia/Shanghai (北京时间, CST-8); 日志等级 6, 系统日志缓冲区 64 KiB;
# NTP 时间服务器换成国内节点。
if command -v uci >/dev/null 2>&1; then
    uci -q set system.@system[0].zonename='Asia/Shanghai'
    uci -q set system.@system[0].timezone='CST-8'
    uci -q set system.@system[0].log_level='6'
    uci -q set system.@system[0].log_size='64'
    uci -q set system.@system[0].ntp_server='ntp.tencent.com' 'ntp.aliyun.com' 'ntp.ntsc.ac.cn' 'cn.ntp.org.cn'
    uci -q commit system
fi
EOF
chmod +x "$UCI_DIR/996-tz-locale"
echo
echo "已写入 files/etc/uci-defaults/996-tz-locale:"
cat "$UCI_DIR/996-tz-locale"

echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
