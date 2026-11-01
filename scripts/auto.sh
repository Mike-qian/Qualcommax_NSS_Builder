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

# --- 首次开机: 把 mike-qian kmod feed 替换为 ppenss feed ---
# TAG 取自 Julius 仓库最新的 ppe-nss-<数字> 开头 tag (构建期联网获取; 失败则回退保留设备自身 TAG)。
# 注意: 排除 ppe-nss-mesh- 等其它 flavor, 只取标准 ppe-nss-<时间戳> 格式。
UCI_DIR="$OPENWRT_DIR/files/etc/uci-defaults"
mkdir -p "$UCI_DIR"

PPENSS_TAG=""
if command -v curl >/dev/null 2>&1; then
  # 优先用 GitHub API, 失败回退到 tags 页面 HTML
  PPENSS_TAG="$(curl -fsSL --retry 3 "https://api.github.com/repos/JuliusBairaktaris/Qualcommax_NSS_Builder/tags?per_page=100" 2>/dev/null \
    | grep -oE '"name":[[:space:]]*"ppe-nss-[0-9][^"]+"' | sed -E 's/.*"ppe-nss-([^"]+)"/ppe-nss-\1/' | sort | tail -1)" || true
  if [[ -z "$PPENSS_TAG" ]]; then
    PPENSS_TAG="$(curl -fsSL --retry 3 "https://github.com/JuliusBairaktaris/Qualcommax_NSS_Builder/tags" 2>/dev/null \
      | grep -oE 'releases/tag/ppe-nss-[0-9][^"#]+' | sed -E 's#releases/tag/##' | sort | tail -1)" || true
  fi
fi

if [[ -n "$PPENSS_TAG" ]]; then
  echo "使用 ppenss feed TAG: $PPENSS_TAG (取自 Julius 最新 ppe-nss-<数字> tag)"
  cat > "$UCI_DIR/998-clean-distfeeds" << EOF
#!/bin/sh
# 将设备自带的 mike-qian kmod feed 替换为 ppenss feed。
# TAG 固定为 $PPENSS_TAG (取自 Julius 仓库最新的 ppe-nss-<数字> tag), 对应 ppenss 已发布的 feed。
# ppenss feed 结构: https://ppenss.github.io/<TAG>/<DEVICE>/packages.adb (发布于根目录)。
[ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i -e '/kiddin9/d' -e 's#mike-qian\.github\.io/Qualcommax_NSS_Builder/[^/]*#ppenss.github.io/$PPENSS_TAG#' /etc/apk/repositories.d/distfeeds.list
EOF
else
  echo "警告: 未能获取 Julius 最新 ppe-nss-<数字> tag, 998 回退为保留设备自身 TAG。" >&2
  cat > "$UCI_DIR/998-clean-distfeeds" << 'EOF'
#!/bin/sh
# 回退: 仅替换主机名+子路径, 保留设备自身构建 TAG (内核才能匹配 kmod 才能加载)。
[ -f /etc/apk/repositories.d/distfeeds.list ] && sed -i -e '/kiddin9/d' -e 's#mike-qian\.github\.io/Qualcommax_NSS_Builder#ppenss.github.io#g' /etc/apk/repositories.d/distfeeds.list
EOF
fi
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

# --- 添加 ppenss 的 APK 签名公钥 (从 ppenss feed 的 base-files.apk 中提取) ---
# 真实文件带版本号 (base-files-<ver>.apk), 先用 GitHub API 解析文件名, 再下载并解包取包内
# etc/apk/keys/ 下的公钥 (即该 feed 的信任锚)。提取失败则不写入任何公钥, 且绝不中断构建。
APK_KEYS_DIR="$OPENWRT_DIR/files/etc/apk/keys"
mkdir -p "$APK_KEYS_DIR"

set +e
KEY_OK=0
if command -v curl >/dev/null 2>&1 && [[ -n "$PPENSS_TAG" ]]; then
  BF_NAME="$(curl -fsSL --retry 3 "https://api.github.com/repos/ppenss/ppenss.github.io/contents/$PPENSS_TAG/xiaomi_ax3600" 2>/dev/null \
    | grep -oE '"name":[[:space:]]*"base-files-[^"]+\.apk"' | sed -E 's/.*"([^"]+)"/\1/' | head -1)"
  if [[ -n "$BF_NAME" ]]; then
    BF_URL="https://raw.githubusercontent.com/ppenss/ppenss.github.io/main/$PPENSS_TAG/xiaomi_ax3600/$BF_NAME"
    BF_TMP="$(mktemp)"
    curl -fsSL --retry 3 "$BF_URL" -o "$BF_TMP" 2>/dev/null
    if [[ -s "$BF_TMP" ]]; then
      # apk 包内成员可能带 ./ 前缀, 统一去掉再匹配 (兼容 GNU tar 与 apk-tools 两种格式)
      KEY_FILE="$(tar -tzf "$BF_TMP" 2>/dev/null | sed -E 's#^\./##' | grep -E '^etc/apk/keys/[^/]+\.(pem|rsa|pub)$' | head -1)"
      if [[ -n "$KEY_FILE" ]]; then
        tar -xzf "$BF_TMP" -O "$KEY_FILE" > "$APK_KEYS_DIR/ppenss.pem" 2>/dev/null
        if grep -q "PUBLIC KEY" "$APK_KEYS_DIR/ppenss.pem" 2>/dev/null; then
          KEY_OK=1
        else
          echo "警告: 提取到的 $KEY_FILE 内容不含 PUBLIC KEY, 已丢弃。" >&2
          rm -f "$APK_KEYS_DIR/ppenss.pem"
        fi
      else
        echo "警告: base-files.apk 内未找到 etc/apk/keys/ 下的公钥, 跳过。" >&2
      fi
    else
      echo "警告: 下载 ppenss base-files.apk 失败 (空文件或网络错误), 跳过公钥写入。" >&2
    fi
    rm -f "$BF_TMP"
  else
    echo "警告: 未在 ppenss 仓库 $PPENSS_TAG/xiaomi_ax3600 找到 base-files-*.apk, 跳过公钥写入。" >&2
  fi
else
  echo "警告: 缺少 curl 或 PPENSS_TAG 为空, 跳过公钥写入。" >&2
fi
set -e

if [[ "$KEY_OK" -eq 1 ]]; then
  echo "已从 ppenss base-files.apk ($BF_NAME) 提取公钥 -> $APK_KEYS_DIR/ppenss.pem"
  echo "公钥内容:"
  cat "$APK_KEYS_DIR/ppenss.pem"
else
  echo "注意: 本次未写入 ppenss 公钥 (仅影响运行时从 ppenss feed 安装包, 不影响刷机与构建)。" >&2
fi
echo
echo "提示: 确认 devices/common/config 中含 CONFIG_PACKAGE_autocore=y"
