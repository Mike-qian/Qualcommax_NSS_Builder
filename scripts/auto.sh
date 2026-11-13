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

# --- 内核配置: qualcommax target 开启 crypto 用户态 API 与 QCE 硬件加速 ---
# 删除旧的 CONFIG_CRYPTO_DEV_QCE / CONFIG_CRYPTO_USER_API* (含 =y 与 " is not set" 两种写法),
# 再统一追加 =y, 确保 IPQ807x 的 QCE 硬件加解密与用户态 crypto API 被编入内核。
F="$OPENWRT_DIR/target/linux/qualcommax/config-6.18"
if [ -f "$F" ]; then
    sed -i -E '/^#? *CONFIG_CRYPTO_DEV_QCE(=| is not set)/d' "$F"
    sed -i -E '/^#? *CONFIG_CRYPTO_USER_API(_SKCIPHER|_HASH|_AEAD)?(=| is not set)/d' "$F"
    # 追加 5 行
    cat >> "$F" <<'EOF'
CONFIG_CRYPTO_DEV_QCE=y
CONFIG_CRYPTO_DEV_QCE_ENABLE_ALL=y
CONFIG_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y
CONFIG_CRYPTO_CHACHA20_NEON=y
CONFIG_CRYPTO_POLY1305_NEON=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_SHA1_ARM64_CE=y
CONFIG_CRYPTO_SHA2_ARM64_CE=y
CONFIG_CRYPTO_GHASH_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_LIB_AES=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA512=y
CONFIG_CRYPTO_USER_API=y
CONFIG_CRYPTO_USER_API_SKCIPHER=y
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_CRYPTO_USER_API_AEAD=y
CONFIG_CRYPTO_AUTHENC=y
CONFIG_CRYPTO_CBC=y
#CONFIG_CRYPTO_XTS=y
CONFIG_CRYPTO_CHACHA20=y
CONFIG_CRYPTO_POLY1305=y
CONFIG_CRYPTO_HMAC=y
#CONFIG_BPF_JIT_ALWAYS_ON=y
EOF
    echo
    echo "已更新内核配置 $F (crypto 用户态 API + QCE 硬件加速 =y)"
else
    echo "警告: 未找到内核配置文件 $F, 跳过 crypto 配置修改。" >&2
fi

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

# --- 首次开机: 时区与系统日志设置 ---
cat > "$UCI_DIR/996-tz-locale" << 'EOF'
#!/bin/sh
# 时区设为 Asia/Shanghai (北京时间, CST-8); 日志等级 log_level/conloglevel 6, cronloglevel 5, 系统日志缓冲区 64 KiB。
if command -v uci >/dev/null 2>&1; then
    uci -q set system.@system[0].zonename='Asia/Shanghai'
    uci -q set system.@system[0].timezone='CST-8'
    uci -q set system.@system[0].log_level='6'
    uci -q set system.@system[0].conloglevel='6'
    uci -q set system.@system[0].log_size='64'
    uci -q commit system
fi
# 立即让配置生效: 重启 log 与 NTP 服务。
[ -x /etc/init.d/log ] && /etc/init.d/log restart 2>/dev/null || true
[ -x /etc/init.d/sysntpd ] && /etc/init.d/sysntpd restart 2>/dev/null || true
EOF
chmod +x "$UCI_DIR/996-tz-locale"
echo
echo "已写入 files/etc/uci-defaults/996-tz-locale:"
cat "$UCI_DIR/996-tz-locale"

# --- 首次开机: 修补 luci.upnp 的端口转发解析正则 ---
# 把 match() 中的 `^\t\tiif` 改为 `^\s*iif`, 并把 `dport ([0-9]+) dnat ip to`
# 改为 `dport ([0-9]+) .*dnat ip to`, 以兼容 @//nh 接口的端口映射输出格式。
cat > "$UCI_DIR/997-fix-luci-upnp" << 'EOF'
#!/bin/sh
# 修补 /usr/share/rpcd/ucode/luci.upnp 中解析 upnp 端口转发行的正则,
# 使其对 @//nh 接口的 nft 规则同样生效。
F="/usr/share/rpcd/ucode/luci.upnp"
if [ -f "$F" ]; then
    # 1) `^\t\tiif` -> `^\s*iif` (ucode 正则: \t 单 tab -> \s 任意空白)
    # 2) `dport ([0-9]+) dnat ip to` -> `dport ([0-9]+) .*dnat ip to`
    #    用 `) dnat ip to` 这一唯一字面片段做替换, 规避 BRE 中 ()[]+ 的特殊含义。
    sed -i -e 's/\\t\\tiif/\\s*iif/' -e 's/) dnat ip to/) .*dnat ip to/' "$F"
    echo "已修补 $F 的 upnp 解析正则。"
else
    echo "警告: 未找到 $F, 跳过 luci.upnp 修补。" >&2
fi
# 重新加载 rpcd 使改动立即生效 (首次开机时若尚未启动则忽略)。
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null || true
EOF
chmod +x "$UCI_DIR/997-fix-luci-upnp"
echo
echo "已写入 files/etc/uci-defaults/997-fix-luci-upnp:"
cat "$UCI_DIR/997-fix-luci-upnp"

echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
