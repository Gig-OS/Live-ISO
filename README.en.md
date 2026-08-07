# Live-ISO

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Build scripts for the Gig-OS Live ISO. The result is a KDE Plasma desktop Live ISO
(`gig-os-YYYYMMDD.iso`) with the Chinese environment, input methods, fonts and graphics drivers
already set up. Run it live, or install it to disk with Calamares.

If you only want to download it, you do not need this repository: take the latest build from
[iso.gentoozh.org](https://iso.gentoozh.org/).

## Requirements

Run as root on Gentoo. You need bash, wget, tar, xz, git, make, m4, rsync, squashfs-tools with xz
support, and asciidoc to build arch-install-scripts.

`arch-scripts` is a git submodule, so clone it too:

```sh
git clone -b KDE --recurse-submodules https://github.com/Gig-OS/Live-ISO.git
```

**Name the branch explicitly.** The upstream build branch is `KDE`, not `main`.

## Building

```sh
sudo ./build.sh
```

`build.sh` is the only entry point. It holds `/run/gigos-build.lock`, so only one build runs at a
time. Options live in `config`, all written as `: "${VAR:=default}"`, so an environment variable
overrides them without editing the file:

```sh
sudo CORES=32 TMPFS=80G ./build.sh
```

The ones you are most likely to change: `CORES` and `MAKEOPTS` set the parallelism; `TMPFS` is the
size of the build tmpfs, and raising it speeds up compilation noticeably when there is enough RAM;
`MIRROR` and `GENTOO_MIRRORS` point at the distfiles source. Adjust
`include-squashfs/etc/portage/make.conf/common` for the host.

Automated builds and releases live in
[gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra); this repository contains
no release logic.

## Layout

| Path | Contents |
|---|---|
| `build.sh` | The build script |
| `config` | Build options, overlay list, extra packages |
| `arch-scripts` | The arch-chroot scripts, a git submodule |
| `hooks/` | Hooks run in order after the system update |
| `include-squashfs/` | Files copied into the squashfs before the update |
| `include-iso/` | Files copied to the ISO root, including the GRUB menu |
| `exclude.txt` | Paths excluded when packing the squashfs |

## Overlays and extra packages

`OVERLAYS` in `config` lists the overlays to add and `EXTRA_PKGS` the additional packages. The three
overlays serve different purposes:

| Overlay | Provides at build time |
|---|---|
| `gig` | `calamares-settings-gig`, `flclash` |
| `gentoo-zh` | `sys-boot/zfsbootmenu`, plus the Chinese packages users install afterwards |

`guru` was dropped on 2026-08-07. It only ever provided `sys-boot/zfsbootmenu`, which `gentoo-zh` now
carries at the same 3.1.0 with all dependencies in the main tree.

## Release sanitisation

`hooks/99-sanitize-for-release.sh` is the release gate and runs before the squashfs is packed. It
deletes build-host-only configuration, including `zz-autounmask` and the build-host `make.conf`
tuning, and asserts that the Calamares install-time cleanup step exists. A failed assertion aborts
the build, because without that step the installed system keeps the live passwordless configuration.

When the gate blocks a build, search the log for `关键` to find the specific item. That marker is
Simplified Chinese in the scripts and must be matched verbatim.

## ZFS root and ZFSBootMenu

The Calamares partitioning page offers ZFS as the root filesystem. Ticking Encrypt uses ZFS native
encryption (aes-256-gcm) booted by ZFSBootMenu, because GRUB cannot read ZFS pools that use newer
features or native encryption. **The passphrase must be at least 8 characters**: ZFS native
encryption requires it, and anything shorter makes `zpool create` fail and aborts the install.

The logic is in `include-squashfs/usr/local/bin/gigos-zfs-bootmenu.sh` and
`gigos-zfs-prebootloader.sh`, invoked by the Calamares shellprocess module.

## Graphics drivers

The boot menu offers open-source nouveau and the proprietary NVIDIA driver. The proprietary module is
unsigned, so Secure Boot must be disabled in the BIOS first; otherwise the kernel refuses to load it
and you get a black screen or a hang. `gigos-nvidia-load.service` modprobes the driver normally
before sddm starts rather than using early KMS.

## Related repositories

- [Gig-OS/gig](https://github.com/Gig-OS/gig): the build overlay
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig): installer configuration
- [Gig-OS/gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra): automated build and release
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror): the download site, iso.gentoozh.org
