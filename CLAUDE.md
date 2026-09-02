# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This repo contains **no OpenWrt source code**. It is a build-orchestration layer: GitHub Actions clones
`padavanonly/immortalwrt-mt798x-6.6` (branch `openwrt-24.10-6.6`) into `/workdir/openwrt` at build time, then
mutates that tree with the scripts here to produce ImmortalWrt firmware for the **Cudy TR3000 v1 (MediaTek
MT7981 / filogic)**.

Everything in this repo is therefore either (a) a saved `.config`, (b) a script that patches someone else's
source tree, or (c) an assertion that the patch actually landed.

## Build targets

Three device variants, each with a saved buildroot config. The workflow input `device` selects one or `all`.

| Input | Config | OpenWrt profile | Notes |
|---|---|---|---|
| `256M` | `config/256m.config` | `DEVICE_cudy_tr3000-v1-256mb` | single-partition U-Boot layout |
| `128M` | `config/128m.config` | `DEVICE_cudy_tr3000-v1` | stock 3-partition layout |
| `128M-Ubootmod` | `config/128muboot.config` | `DEVICE_cudy_tr3000-v1-ubootmod` | **the fully customized image**; expanded UBI |

`128muboot.config` is the one that actually carries the custom package set (AdGuard Home, Tailscale, UA3F,
DDNS, …). `128m.config` and `256m.config` are near-stock plus OpenClash. Only `128M-Ubootmod` is
gated by `verify-128muboot-config.sh`.

## Build pipeline (`.github/workflows/openwrt-builder.yml`)

Order matters and is the single most important thing to understand:

1. Clone upstream source → `/workdir/openwrt`, symlinked as `$GITHUB_WORKSPACE/openwrt`
2. `diy-part1.sh` — **before** `feeds update/install`
3. `./scripts/feeds update -a && ./scripts/feeds install -a`
4. `diy-part2.sh` — **after** feeds are installed
5. Per-device loop: `cp config/<dev>.config .config` → `make defconfig` → (ubootmod only)
   `verify-128muboot-config.sh .config` → `make download -j$(nproc)` → `make -j$(nproc)`, falling back to
   `make -j1 V=s` on failure
6. Collect `bin/targets/**/*sysupgrade.bin` → artifact / Release

Both DIY scripts run with **cwd = the OpenWrt tree**, while the repo itself is at `$GITHUB_WORKSPACE`. Relative
paths like `feeds/packages/...`, `package/...`, `files/...`, `target/linux/...`, `include/image.mk` refer to the
OpenWrt tree, not this repo.

Steps 2–4 run **once**, before the loop — so every device build in an `all` run shares the same patched tree and
the same `files/` overlay.

### diy-part1 vs diy-part2

- `diy-part1.sh`: feed-source edits and packages that must exist before `feeds install` resolves symbols. Copies
  `package/luci-compat-keep` from this repo into the tree; clones the Aurora theme and Bandix packages.
- `diy-part2.sh`: everything that patches installed feed content (`feeds/packages/...`, `feeds/luci/...`),
  the DTS, `include/image.mk`, plus pinned third-party clones and the `files/` rootfs overlay.

Other workflows: `uboot-builder.yml` builds DHCP U-Boot from `weekdaycare/bl-mt798x-dhcpd` (unrelated to the
OpenWrt build); `update-checker.yml` polls upstream monthly and dispatches a full `all` build on new commits.

## The fail-loudly contract

`diy-part2.sh` runs `set -Eeuo pipefail` and is built around four helpers. **Preserve this style in any edit** —
the design goal is that upstream drift breaks the build immediately rather than silently producing a firmware
image missing a patch:

- `require_file` — the file it is about to patch must exist
- `expect_count N NEEDLE FILE` — asserts an exact occurrence count, used both as a **precondition** (e.g.
  `expect_count 1 'PKG_VERSION:=0.107.57'` before rewriting the AdGuard Home Makefile) and as a
  **postcondition** after each `sed`
- `clone_package` — fetches a single pinned commit and verifies `rev-parse HEAD` matches
- `download_verified` — `wget` + `sha256sum -c`

Never replace an assertion with a permissive `grep || true`, and never make a `sed` "best effort". If a
precondition now fails because upstream moved, update the pinned constant and re-derive the hash — do not
weaken the check.

### Pinned versions

All pins live in one `readonly` block at the top of `diy-part2.sh`: UA3F / OpenClash-core / AdGuard-rules
commits, the OpenClash core and AGH rules SHA-256s, `ADGUARDHOME_VERSION`, and `TAILSCALE_RETAINED_VERSION`.

**Gotcha:** the AdGuard Home archive SHA-256 appears *twice* — as `ADGUARDHOME_ARCHIVE_SHA256` and hardcoded as
`HASH:=` inside the generated Makefile heredoc (heredoc is quoted, so no interpolation). A trailing
`expect_count` catches a mismatch, but both must be edited together.


### Toolchain constraints driving the pins

The 24.10 feed ships Go 1.23.12, asserted explicitly against `feeds/packages/lang/golang/golang/Makefile`.
Because of this:

- **AdGuard Home** (needs Go 1.26+) is not built from source. `diy-part2.sh` overwrites its Makefile with a
  recipe that downloads AdGuard's official static AArch64 release and installs it, reusing the feed's existing
  `files/adguardhome.init` and `files/adguardhome.config`. `Build/Configure` and `Build/Compile` are empty.
- **Tailscale** is deliberately *held back* at 1.80.3 rather than bumping the whole toolchain.
- `feeds/packages/lang/rust/Makefile` gets `ci-llvm=true → false` (long-standing build-failure workaround).

## Config contract: `verify-128muboot-config.sh`

Runs against `.config` after `make defconfig` for the ubootmod build and fails the job on any violation. Two
lists: `required_symbols` (must be `CONFIG_X=y`) and `disabled_symbols` (must be neither `=y` nor `=m`).

This is the closest thing to a test suite here, and it **is runnable on macOS**:

```bash
./verify-128muboot-config.sh config/128muboot.config
```

Note it is intentionally checked against the *post-`defconfig`* `.config` in CI, so a locally clean run of the
saved config does not guarantee CI passes — `defconfig` can pull in or drop symbols.

The disabled list encodes real decisions, not just noise: `dnsmasq` off / `dnsmasq-full` on, `tcpdump` off /
`tcpdump-mini` on, `luci-app-adguardhome` off while `adguardhome` itself is on, and a long list of heavy
packages kept out for Actions disk/time budget.

**When you add or remove a package in `config/128muboot.config`, update the corresponding list in this script
in the same change.** Prefer asserting the concrete variant actually selected (e.g. `miniupnpd-nftables`, not
just `miniupnpd`).

## Editing configs

The intended path is the **menuconfig job**: dispatch `openwrt-builder.yml` with `ssh: true` and a single
device (not `all`). It restores the saved config, opens an Upterm SSH session (`limit-access-to-actor`,
90 min), then commits the resulting `.config` back to the current branch. The `build` job then runs from that
pushed state.

Hand-editing a `.config` is fine for small, well-understood changes, but keep these in sync:

- `CONFIG_CCACHE_DIR` in all three configs must match `CCACHE_DIR` in the workflow env (`/workdir/.ccache`);
  the cache key also hashes `config/*.config`.
- `CONFIG_CCACHE=y` is what wraps host *and* target compilers — do not reintroduce manual `ccache` compiler
  wrappers in the workflow.
- `CONFIG_PACKAGE_luci-compat-keep=y` pins `luci-compat` so OpenClash's dependency survives app updates.

## Runtime image defaults

Baked in via `files/etc/uci-defaults/` from `diy-part2.sh`:

- `99-lan-ip` sets LAN to **192.168.6.1** (nothing else in the network topology is changed)
- `98-service-defaults` disables `openclash adguardhome ua3f ddns` on first boot (they need credentials) and
  enables the Tailscale init script. Tailscale's own uci `enabled` option still defaults to 0, so its daemon
  stays down until it is switched on in LuCI. Keep new credential-requiring services in the disable list.
- `files/etc/adguardhome-filter-presets.yaml` is an **inactive** preset (filters + 1240 user rules, asserted
  exactly), deliberately stripped of credentials/upstreams/ports/DHCP. It is not `AdGuardHome.yaml`.
- `files/etc/openclash/core/clash_meta` — the arm64 Meta core, verified to be an `ARM aarch64` ELF; the feed's
  expected path is asserted before install.

## Local development on macOS

`diy-part2.sh` is Linux-only: it relies on GNU `sed -i` (no backup suffix), `sha256sum`, and an OpenWrt tree at
cwd. Do not try to execute it here. What you *can* do locally:

```bash
for f in diy-part1.sh diy-part2.sh verify-128muboot-config.sh; do bash -n "$f"; done  # syntax check
./verify-128muboot-config.sh config/128muboot.config           # config contract
```

There is no linter, formatter, or test runner configured in CI.

## Known documentation drift

`README.md` says the 122M UBI expansion is opt-in via uncommenting a `sed` in `diy-part2.sh`. That is stale:
`diy-part2.sh` now applies the expansion **unconditionally** (`0x5c0000 0x7000000` → `0x5c0000 0x7a40000`,
model string `ubi 112M` → `ubi 122M`) with postconditions asserting the 112M values are gone. To build a 112M
image you would have to remove that block *and* its assertions.
