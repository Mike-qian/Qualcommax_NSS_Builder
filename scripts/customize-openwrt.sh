#!/usr/bin/env bash
# Customize a checked-out OpenWrt tree before the build:
#   1. raise the netfilter connection-tracking limit to 65535
#   2. add the Argon theme and HomeProxy feeds (argon, homeproxy)
#   3. add the Chinese LuCI translations, the Argon theme and HomeProxy to
#      the shared config
#
# Runs over the freshly checked-out source, before prepare-build.sh: the
# feeds land in feeds.conf early enough for the `feeds update/install -a`
# and `make defconfig` there, so their packages resolve into .config and can
# be selected like any other. The conntrack files ride the image from here
# on, and the shared config in the builder repo gains the LuCI extras.
# Idempotent - re-running changes nothing.
#
# Required env:
#   OPENWRT_DIR   path to the checked-out OpenWrt source

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

# append_config <file> <line>: append a line to a config file, putting a
# newline first if the file does not end with one - a config that lost its
# trailing newline would otherwise be silently joined to the appended line.
append_config() {
  local file=$1 text=$2
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
    printf '\n' >>"$file"
  fi
  printf '%s\n' "$text" >>"$file"
}

: "${OPENWRT_DIR:?OPENWRT_DIR required}"

CONNTRACK_MAX=65535

# Upstream feeds for the extra packages. Both are single-package repos, so
# one feed line is one package:
#   argon     - jerrykuku's LuCI theme (luci-theme-argon)
#   homeproxy - ImmortalWrt's proxy platform (luci-app-homeproxy, powered
#               by sing-box), pinned to its dev branch
FEEDS=(
  "argon https://github.com/jerrykuku/luci-theme-argon.git"
  "homeproxy https://github.com/immortalwrt/homeproxy.git;dev"
)

# The builder repo, from this script's own path: the shared config below is
# edited there. Resolved before the cd, which turns the relative $0 form
# into a path that no longer exists.
BUILDER_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"

cd "$OPENWRT_DIR"

# 1. Connection-tracking limit.
# The kernel default (16384 on small-RAM devices, RAM-derived otherwise) is
# small for a busy NAT table: past it the kernel logs "nf_conntrack: table
# full, dropping packet" and new connections stall until old ones expire.
#
# Two files ride the image:
#   etc/sysctl.d/10-conntrack-max.conf - /etc/init.d/sysctl applies it at
#     every boot, before the firewall
#   etc/uci-defaults/98-conntrack-max - applies it on first boot and after
#     every sysupgrade (uci-defaults re-run there), and records the value
#     in /etc/sysctl.conf, which sysupgrade preserves
log::info "Setting the connection-tracking limit to $CONNTRACK_MAX"
mkdir -p files/etc/sysctl.d files/etc/uci-defaults
printf 'net.netfilter.nf_conntrack_max=%s\n' "$CONNTRACK_MAX" \
  >files/etc/sysctl.d/10-conntrack-max.conf

cat >files/etc/uci-defaults/98-conntrack-max <<EOF
#!/bin/sh
# Applied once and recorded in uci - the marker lives in /etc/config/system,
# which a settings-preserving sysupgrade keeps, so a user who moved the
# limit further keeps their value. Same pattern as 999-QOL_config.
[ "\$(uci -q get system.@system[0].conntrack_max)" = "$CONNTRACK_MAX" ] && exit 0

# nf_conntrack is a module: its parameters do not exist until it is loaded
# (fw4 loads it when the firewall starts).
modprobe nf_conntrack 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_max=$CONNTRACK_MAX 2>/dev/null || true

# Persist in /etc/sysctl.conf: sysupgrade keeps the file and
# /etc/init.d/sysctl applies it at every boot. Drop any existing line
# first, so a re-run of this script cannot grow the file.
sed -i '/^net\.netfilter\.nf_conntrack_max[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null || true
echo 'net.netfilter.nf_conntrack_max=$CONNTRACK_MAX' >>/etc/sysctl.conf

uci -q set system.@system[0].conntrack_max='$CONNTRACK_MAX'
uci commit system
exit 0
EOF
chmod 0755 files/etc/uci-defaults/98-conntrack-max

# 2. Argon theme and HomeProxy feeds.
[[ -f feeds.conf ]] || cp feeds.conf.default feeds.conf

for entry in "${FEEDS[@]}"; do
  read -r name url <<<"$entry"
  line="src-git ${name} ${url}"
  if grep -qxF "$line" feeds.conf; then
    log::info "Feed $name already in feeds.conf"
  else
    log::info "Adding feed: $line"
    # A feed of the same name is replaced, so a fork can stand in for a
    # default one - the same rule prepare-build.sh applies to FEEDS.
    sed -i -E "/^src-\S+[[:space:]]+${name}[[:space:]]/d" feeds.conf
    printf '%s\n' "$line" >>feeds.conf
  fi
  # Update + install this feed alone; the default feeds are prepare-build's
  # business. Installing makes the packages selectable in .config - nothing
  # is built unless a config line picks it.
  log::info "Updating + installing feed: $name"
  ./scripts/feeds update "$name"
  ./scripts/feeds install -a -p "$name"
done

# 3. Chinese LuCI translations, the Argon theme and HomeProxy.
# Package selections in the shared config, so every board gets them; they are
# added here so the package list sits with the rest of the build's
# customizations. The symbols must exist when prepare-build.sh runs
# `make defconfig` and checks them, which is why this comes after the feeds
# above: the theme ships in jerrykuku's own feed, HomeProxy in its own.
#
# Current LuCI has no standalone language packages: every package with a po/
# tree generates hidden luci-i18n-<app>-<locale> subpackages whose default is
# `LUCI_LANG_<locale>||(ALL&&m)` (the LuciTranslation macro in luci.mk), so
# one symbol turns on Simplified Chinese for every LuCI package in the image
# - the base UI, the admin modules and the apps alike. zh_Hans is the po/
# directory (its zh-cn alias names the subpackages); the symbol lives in
# luci-base's config, so it exists as long as luci is selected.
#
# The default language is not a package: prepare-build.sh layers
# devices/common/files over the image, and the /etc/config/luci there pins
# option lang 'zh_cn'.
BUILDER_CONFIG="$BUILDER_DIR/devices/common/config"
[ -f "$BUILDER_CONFIG" ] || log::die "no devices/common/config under $BUILDER_DIR"

CONFIG_LINES=(
  "CONFIG_LUCI_LANG_zh_Hans=y"
  "CONFIG_PACKAGE_luci-theme-argon=y"
  "CONFIG_PACKAGE_luci-app-homeproxy=y"
)
marker='# Chinese LuCI translations, Argon and HomeProxy (customize-openwrt.sh)'
for line in "${CONFIG_LINES[@]}"; do
  if grep -qxF "$line" "$BUILDER_CONFIG"; then
    log::info "$line already in devices/common/config"
    continue
  fi
  # The marker makes the block findable (and removable) later; each config
  # line is checked on its own, so a re-run duplicates neither.
  grep -qxF "$marker" "$BUILDER_CONFIG" ||
    append_config "$BUILDER_CONFIG" "$marker"
  append_config "$BUILDER_CONFIG" "$line"
  log::info "Added $line to devices/common/config"
done

log::info "OpenWrt tree customized."
