#!/usr/bin/env bash

set -Eeuo pipefail

readonly CONFIG_FILE="${1:-.config}"

error_count=0

fail() {
  printf 'CONFIG VERIFICATION FAILED: %s\n' "$*" >&2
  exit 1
}

report_error() {
  printf 'CONFIG VERIFICATION ERROR: %s\n' "$*" >&2
  error_count=$((error_count + 1))
}

require_enabled() {
  local symbol="$1"
  if ! grep -Fxq "CONFIG_${symbol}=y" "$CONFIG_FILE"; then
    report_error "CONFIG_${symbol} must be built into the firmware"
  fi
}

require_disabled() {
  local symbol="$1"
  if grep -Fxq "CONFIG_${symbol}=y" "$CONFIG_FILE" ||
     grep -Fxq "CONFIG_${symbol}=m" "$CONFIG_FILE"; then
    report_error "CONFIG_${symbol} must remain disabled"
  fi
}

[ -f "$CONFIG_FILE" ] || fail "config file not found: $CONFIG_FILE"

required_symbols=(
  TARGET_mediatek
  TARGET_mediatek_filogic
  TARGET_mediatek_filogic_DEVICE_cudy_tr3000-v1-ubootmod
  PACKAGE_luci-app-openclash
  PACKAGE_adguardhome
  PACKAGE_tailscale
  PACKAGE_luci-app-tailscale
  PACKAGE_smart-srun
  PACKAGE_luci-app-smart-srun
  PACKAGE_ua3f
  PACKAGE_ddns-scripts
  PACKAGE_ddns-scripts-cloudflare
  PACKAGE_luci-app-ddns
  PACKAGE_kmod-usb-net-cdc-ncm
  PACKAGE_usbutils
  PACKAGE_ip-full
  PACKAGE_curl
  PACKAGE_wget-ssl
  PACKAGE_ca-bundle
  PACKAGE_ca-certificates
  PACKAGE_jq
  PACKAGE_ethtool
  PACKAGE_tcpdump-mini
  PACKAGE_coreutils-timeout
  PACKAGE_flock
  PACKAGE_luci-app-ttyd
  PACKAGE_luci-app-wol
  PACKAGE_etherwake
  PACKAGE_luci-app-bandix
  PACKAGE_bandix
  PACKAGE_luci-theme-aurora
  PACKAGE_luci-app-aurora-config
  PACKAGE_dnsmasq-full
  PACKAGE_bash
  PACKAGE_kmod-tun
  PACKAGE_unzip
  PACKAGE_ruby
  PACKAGE_ruby-yaml
  PACKAGE_luci-compat
  PACKAGE_kmod-inet-diag
  PACKAGE_kmod-nft-tproxy
  PACKAGE_kmod-nft-socket
  PACKAGE_odhcp6c
  PACKAGE_odhcpd-ipv6only
  PACKAGE_firewall4
  PACKAGE_nftables-json
  PACKAGE_kmod-nft-nat
  PACKAGE_kmod-usb-net-rndis
  PACKAGE_kmod-usb-net-cdc-ether
  PACKAGE_python3-light
  PACKAGE_python3-urllib
  PACKAGE_ipset
  PACKAGE_iptables-nft
  PACKAGE_iptables-mod-tproxy
  PACKAGE_iptables-mod-extra
  PACKAGE_iptables-mod-ipopt
  PACKAGE_iptables-mod-nfqueue
  PACKAGE_iptables-mod-conntrack-extra
  PACKAGE_kmod-nf-conntrack-netlink
)

disabled_symbols=(
  PACKAGE_luci-app-smart-srun-bundle
  PACKAGE_luci-app-adguardhome
  PACKAGE_dnsmasq
  PACKAGE_tcpdump
  PACKAGE_luci-app-passwall
  PACKAGE_luci-app-passwall2
  PACKAGE_mosdns
  PACKAGE_luci-app-mosdns
  PACKAGE_smartdns
  PACKAGE_luci-app-smartdns
  PACKAGE_mwan3
  PACKAGE_luci-app-mwan3
  PACKAGE_pbr
  PACKAGE_luci-app-pbr
  PACKAGE_xray-core
  PACKAGE_sing-box
  PACKAGE_dockerd
  PACKAGE_docker
  PACKAGE_luci-app-dockerman
  PACKAGE_samba4-server
  PACKAGE_luci-app-samba4
  PACKAGE_luci-app-samba
  PACKAGE_alist
  PACKAGE_luci-app-alist
  PACKAGE_transmission-daemon
  PACKAGE_luci-app-transmission
  PACKAGE_aria2
  PACKAGE_luci-app-aria2
  PACKAGE_miniupnpd
  PACKAGE_miniupnpd-nftables
  PACKAGE_luci-app-upnp
  PACKAGE_coremark
  PACKAGE_luci-app-coremark
)

for symbol in "${required_symbols[@]}"; do
  require_enabled "$symbol"
done

for symbol in "${disabled_symbols[@]}"; do
  require_disabled "$symbol"
done

if [ "$error_count" -ne 0 ]; then
  fail "$error_count config contract violation(s) found in $CONFIG_FILE"
fi

printf 'Verified %d required and %d disabled config symbols in %s\n' \
  "${#required_symbols[@]}" \
  "${#disabled_symbols[@]}" \
  "$CONFIG_FILE"
