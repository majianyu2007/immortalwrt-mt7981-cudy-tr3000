#!/usr/bin/env bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.

set -Eeuo pipefail

readonly SMART_SRUN_COMMIT="ef00018a06593cbd2d3b424d1532dcc88d8b8246"
readonly UA3F_COMMIT="23923d4dd813a5e15c2d896acf30bcb357f42fd1"
readonly OPENCLASH_CORE_COMMIT="6625f341886253db3e44f9ded0cc1cd6b8bcbc3d"
readonly OPENCLASH_CORE_SHA256="8252d16726041872825cdd9089c798c318f8862466b40b34d8bf62225ef57e34"
readonly AGH_RULES_COMMIT="67fdd7759035221e59ce7f5b5ce05c83207e91a7"
readonly AGH_RULES_SHA256="20bda9741dcbf0737f254f4af5f4632ace7ad9d257a198eaa05835c64a6fb549"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || die "required file is missing: $1"
}

expect_count() {
  local expected="$1"
  local needle="$2"
  local file="$3"
  local actual

  actual="$(grep -Fc -- "$needle" "$file" || true)"
  [ "$actual" -eq "$expected" ] ||
    die "expected $expected occurrence(s) of '$needle' in $file, found $actual"
}

clone_package() {
  local name="$1"
  local url="$2"
  local commit="$3"
  local destination="$4"
  local resolved

  rm -rf "$destination"
  git init -q "$destination"
  git -C "$destination" remote add origin "$url"
  git -C "$destination" fetch --depth 1 origin "$commit"
  git -C "$destination" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  resolved="$(git -C "$destination" rev-parse HEAD)"
  [ "$resolved" = "$commit" ] ||
    die "$name resolved to $resolved instead of pinned commit $commit"
}

download_verified() {
  local label="$1"
  local url="$2"
  local expected_sha256="$3"
  local destination="$4"

  wget -q --timeout=30 --tries=3 -O "$destination" "$url" ||
    die "failed to download $label from $url"
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum -c - >/dev/null ||
    die "$label failed SHA-256 verification"
}

# Keep the existing Rust workaround, but make repeated invocations harmless.
readonly RUST_MAKEFILE="feeds/packages/lang/rust/Makefile"
require_file "$RUST_MAKEFILE"
sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_MAKEFILE"

# Add the build date to image names exactly once.
readonly IMAGE_MAKEFILE="include/image.mk"
require_file "$IMAGE_MAKEFILE"
grep -q '^IMG_PREFIX:=' "$IMAGE_MAKEFILE" ||
  die "IMG_PREFIX was not found in $IMAGE_MAKEFILE"
if ! grep -Fq 'BUILD_DATE := $(shell date +%Y%m%d)' "$IMAGE_MAKEFILE"; then
  sed -i '/^IMG_PREFIX:=/i BUILD_DATE := $(shell date +%Y%m%d)' "$IMAGE_MAKEFILE"
fi
if ! grep -E '^IMG_PREFIX:=.*\$\(BUILD_DATE\)' "$IMAGE_MAKEFILE" >/dev/null; then
  sed -i '/^IMG_PREFIX:=/ s/\($(SUBTARGET)\)/\1-$(BUILD_DATE)/' "$IMAGE_MAKEFILE"
fi
expect_count 1 'BUILD_DATE := $(shell date +%Y%m%d)' "$IMAGE_MAKEFILE"

# Expand only the TR3000 U-Boot-mod UBI partition: 0x5c0000 + 0x7a40000 = 0x8000000.
readonly TR3000_DTS="target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts"
require_file "$TR3000_DTS"
if grep -Fq 'reg = <0x5c0000 0x7000000>;' "$TR3000_DTS"; then
  sed -i 's/reg = <0x5c0000 0x7000000>;/reg = <0x5c0000 0x7a40000>;/' "$TR3000_DTS"
fi
if grep -Fq 'model = "Cudy TR3000 v1 ubi 112M";' "$TR3000_DTS"; then
  sed -i 's/model = "Cudy TR3000 v1 ubi 112M";/model = "Cudy TR3000 v1 ubi 122M";/' "$TR3000_DTS"
fi
expect_count 1 'reg = <0x5c0000 0x7a40000>;' "$TR3000_DTS"
expect_count 0 'reg = <0x5c0000 0x7000000>;' "$TR3000_DTS"
expect_count 1 'model = "Cudy TR3000 v1 ubi 122M";' "$TR3000_DTS"
expect_count 0 'model = "Cudy TR3000 v1 ubi 112M";' "$TR3000_DTS"

# Inject pinned third-party packages after feeds are installed.
mkdir -p package
clone_package \
  "SMART SRun" \
  "https://github.com/matthewlu070111/smart-srun.git" \
  "$SMART_SRUN_COMMIT" \
  "package/smart-srun"
clone_package \
  "UA3F" \
  "https://github.com/SunBK201/UA3F.git" \
  "$UA3F_COMMIT" \
  "package/UA3F"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# OpenClash reads the Meta core from this exact path. Bundle only the arm64 Meta core.
readonly OPENCLASH_CORE_SCRIPT="feeds/luci/applications/luci-app-openclash/root/usr/share/openclash/openclash_core.sh"
require_file "$OPENCLASH_CORE_SCRIPT"
grep -Fq 'meta_core_path="/etc/openclash/core/clash_meta"' "$OPENCLASH_CORE_SCRIPT" ||
  die "OpenClash Meta core path changed; inspect the feed before continuing"

readonly OPENCLASH_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/${OPENCLASH_CORE_COMMIT}/master/meta/clash-linux-arm64.tar.gz"
core_archive="$tmp_dir/clash-linux-arm64.tar.gz"
core_extract="$tmp_dir/openclash-meta"
download_verified \
  "OpenClash Meta core" \
  "$OPENCLASH_CORE_URL" \
  "$OPENCLASH_CORE_SHA256" \
  "$core_archive"
mkdir -p "$core_extract"
tar -xzf "$core_archive" -C "$core_extract"
require_file "$core_extract/clash"
core_file_type="$(file "$core_extract/clash")"
printf '%s\n' "$core_file_type"
printf '%s\n' "$core_file_type" | grep -Fq 'ARM aarch64' ||
  die "OpenClash Meta core is not an AArch64 ELF binary"
rm -rf files/etc/openclash/core
install -Dm0755 "$core_extract/clash" files/etc/openclash/core/clash_meta

# Freeze only the selected AdGuard Home filters and all 1,240 user rules.
# This is an inactive preset; the official package keeps first-run setup and service disabled.
readonly AGH_RULES_URL="https://raw.githubusercontent.com/liuzq2002/Adguard-Home-For-Magisk-Mod/${AGH_RULES_COMMIT}/Adguardhome/bin/AdGuardHome.yaml"
agh_source="$tmp_dir/AdGuardHome.yaml"
agh_preset="files/etc/adguardhome-filter-presets.yaml"
download_verified \
  "AdGuard Home rule snapshot" \
  "$AGH_RULES_URL" \
  "$AGH_RULES_SHA256" \
  "$agh_source"
mkdir -p "$(dirname "$agh_preset")"
{
  printf '%s\n' \
    '# Inactive AdGuard Home filter preset; merge explicitly after first-run setup.' \
    "# Source commit: ${AGH_RULES_COMMIT}" \
    "# Source SHA-256: ${AGH_RULES_SHA256}" \
    '# Deliberately excludes credentials, DNS upstreams, ports, DHCP, and redirect rules.'
  sed -n '/^filters:/,/^dhcp:/p' "$agh_source" | sed '$d'
} >"$agh_preset"
expect_count 1 'https://raw.githubusercontent.com/8680/GOODBYEADS/master/data/rules/dns.txt' "$agh_preset"
expect_count 1 'https://raw.githubusercontent.com/8680/GOODBYEADS/master/data/rules/allow.txt' "$agh_preset"
expect_count 1 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt' "$agh_preset"
user_rule_count="$(sed -n '/^user_rules:/,$p' "$agh_preset" | grep -c '^  - ' || true)"
[ "$user_rule_count" -eq 1240 ] ||
  die "expected 1240 AdGuard Home user rules, found $user_rule_count"
expect_count 0 'dhcp:' "$agh_preset"

# Change only the LAN address on first boot; preserve the stock network topology.
mkdir -p files/etc/uci-defaults
cat >files/etc/uci-defaults/99-lan-ip <<'EOF'
#!/bin/sh

uci -q set network.lan.ipaddr='192.168.6.1'
uci -q commit network

exit 0
EOF
chmod 0755 files/etc/uci-defaults/99-lan-ip

# Keep optional network services inert until the user supplies local credentials/configuration.
cat >files/etc/uci-defaults/98-disable-unconfigured-services <<'EOF'
#!/bin/sh

for service in openclash adguardhome tailscale smart_srun ua3f ddns; do
  [ ! -x "/etc/init.d/$service" ] || "/etc/init.d/$service" disable
done

exit 0
EOF
chmod 0755 files/etc/uci-defaults/98-disable-unconfigured-services

printf '%s\n' \
  "Pinned SMART SRun: $SMART_SRUN_COMMIT" \
  "Pinned UA3F: $UA3F_COMMIT" \
  "Pinned OpenClash Meta core: $OPENCLASH_CORE_COMMIT" \
  "Pinned AdGuard Home rules: $AGH_RULES_COMMIT ($user_rule_count user rules)"
