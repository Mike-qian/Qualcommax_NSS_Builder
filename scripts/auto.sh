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

# --- 内核配置: qualcommax target 开启 ARMv8 CE 软件加速与基础 crypto 选项 ---
F="$OPENWRT_DIR/target/linux/qualcommax/config-6.18"
if [ -f "$F" ]; then
    while IFS= read -r line; do
        # 跳过空行和以 # 开头的注释行
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        # 提取配置名（例如 CONFIG_CRYPTO_AES_ARM64_CE）
        if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
            cfg_name="${BASH_REMATCH[1]}"
            
            # 1. 已经是 =y，跳过
            if grep -q "^${cfg_name}=y" "$F"; then
                continue
            # 2. 存在但状态不同（如 =m、=n 或 `# CONFIG_xxx is not set`），修改为 =y
            elif grep -q -E "^(#\s*)?${cfg_name}(=|\s+is not set)" "$F"; then
                sed -i -E "s/^#?[[:space:]]*${cfg_name}(=.*|[[:space:]]+is not set).*/${cfg_name}=y/" "$F"
            # 3. 完全不存在，追加到文件末尾
            else
                echo "${cfg_name}=y" >> "$F"
            fi
        fi
    done << 'EOF'
CONFIG_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y
CONFIG_CRYPTO_CHACHA20_NEON=y
CONFIG_CRYPTO_POLY1305_NEON=y
CONFIG_CRYPTO_AES_ARM64_BS=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_SHA1_ARM64_CE=y
CONFIG_CRYPTO_SHA2_ARM64_CE=y
CONFIG_CRYPTO_GHASH_ARM64_CE=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_LIB_AES=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_SHA512=y
CONFIG_CRYPTO_AUTHENC=y
CONFIG_CRYPTO_CBC=y
CONFIG_CRYPTO_CHACHA20=y
CONFIG_CRYPTO_POLY1305=y
CONFIG_CRYPTO_HMAC=y
CONFIG_CRYPTO_GHASH=y
CONFIG_CRYPTO_SHA1=y
CONFIG_CRYPTO_SHA2=y
CONFIG_CRYPTO_RNG_DEFAULT=y
CONFIG_NF_CONNTRACK_MARK=y
EOF

    echo
    echo "已更新内核配置 $F (ARMv8 CE 软件加速 + 基础 crypto =y)"
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
cat > "$UCI_DIR/997-fix-luci-upnp" << 'EOF'
#!/bin/sh
F="/usr/share/rpcd/ucode/luci.upnp"
if [ -f "$F" ]; then
    sed -i -e 's/\\t\\tiif/\\s*iif/' -e 's/) dnat ip to/) .*dnat ip to/' "$F"
    echo "已修补 $F 的 upnp 解析正则。"
else
    echo "警告: 未找到 $F, 跳过 luci.upnp 修补。" >&2
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null || true
EOF
chmod +x "$UCI_DIR/997-fix-luci-upnp"
echo
echo "已写入 files/etc/uci-defaults/997-fix-luci-upnp:"
cat "$UCI_DIR/997-fix-luci-upnp"

echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
