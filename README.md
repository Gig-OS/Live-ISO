# Live-ISO

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Gig-OS Live ISO 的构建脚本。产物是 KDE Plasma 桌面 Live ISO（`gig-os-YYYYMMDD.iso`），预置中文环境、输入法、字体与显卡驱动，可直接试用，也可用 Calamares 安装到硬盘。

只想下载的话不需要本仓库，到 [iso.gentoozh.org](https://iso.gentoozh.org/) 取最新一版即可。

## 环境要求

在 Gentoo 上以 root 执行。需要 bash、wget、tar、xz、git、make、m4、rsync、带 xz 支持的 squashfs-tools，以及构建 arch-install-scripts 用的 asciidoc。

`arch-scripts` 是 git 子模块，克隆时要一并取：

```sh
git clone -b KDE --recurse-submodules https://github.com/Gig-OS/Live-ISO.git
```

**分支必须显式指定。** 上游的构建分支是 `KDE`，不是 `main`。

## 构建

```sh
sudo ./build.sh
```

`build.sh` 是唯一入口，它持有 `/run/gigos-build.lock`，同一时刻只允许一锅在执行。构建选项在 `config`，全部写成 `: "${VAR:=默认值}"`，可以直接用环境变量覆盖而不改文件：

```sh
sudo CORES=32 TMPFS=80G ./build.sh
```

常用项：`CORES` 与 `MAKEOPTS` 决定并发；`TMPFS` 是构建用 tmpfs 大小，内存足够时调大能显著加快编译；`MIRROR` 与 `GENTOO_MIRRORS` 指向 distfiles 源。按本机需求改 `include-squashfs/etc/portage/make.conf/common`。

自动化构建与发布在 [gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra)，本仓库不含发布逻辑。

## 目录

| 路径 | 内容 |
|---|---|
| `build.sh` | 构建主脚本 |
| `config` | 构建选项、overlay 列表、额外软件包 |
| `arch-scripts` | arch-chroot 系列脚本，git 子模块 |
| `hooks/` | 系统更新完成后依次执行的钩子 |
| `include-squashfs/` | 更新前复制进 squashfs 的文件 |
| `include-iso/` | 复制到 ISO 根的文件，含 GRUB 菜单 |
| `exclude.txt` | 打包 squashfs 时排除的路径 |

## overlay 与额外软件包

`config` 的 `OVERLAYS` 定义要加的 overlay，`EXTRA_PKGS` 定义额外安装的包。三个 overlay 各自的作用不同：

| overlay | 构建期提供 |
|---|---|
| `gig` | `calamares-settings-gig`、`flclash` |
| `gentoo-zh` | `sys-boot/zfsbootmenu`，以及装好系统后用户要用的中文包 |

`guru` 已于 2026-08-07 移除。它此前只提供 `sys-boot/zfsbootmenu`，该包现在 `gentoo-zh` 里也有，同为 3.1.0，依赖全在主树。

## 出厂清理

`hooks/99-sanitize-for-release.sh` 是发布前的闸门，在打包进 squashfs 之前执行。它删除构建机专属配置，包括 `zz-autounmask` 与 build-host 的 `make.conf` 调优，并强制检查 Calamares 的装机清理步骤存在。检查不过即中止构建，因为缺少该步骤会让装好的系统残留 live 的免密配置。

被闸门拦下时，在日志里搜 `关键` 定位具体条目。

## ZFS 根与 ZFSBootMenu

Calamares 分区页可以选 ZFS 作根文件系统。勾选加密时使用 ZFS 原生加密（aes-256-gcm），由 ZFSBootMenu 引导，因为 GRUB 读不了带新特性或原生加密的 ZFS 池。**口令至少 8 位**，这是 ZFS 原生加密的硬性要求，更短会让 `zpool create` 失败、安装中止。

相关逻辑在 `include-squashfs/usr/local/bin/gigos-zfs-bootmenu.sh` 与 `gigos-zfs-prebootloader.sh`，由 Calamares 的 shellprocess 调用。

## 显卡驱动

启动菜单提供开源 nouveau 与闭源 NVIDIA 两条路径。闭源模块未签名，需要先在 BIOS 关闭 Secure Boot，否则内核拒绝加载，表现为黑屏或卡住。驱动由 `gigos-nvidia-load.service` 在 sddm 启动前正常 modprobe，不走 early KMS。

## 相关仓库

- [Gig-OS/gig](https://github.com/Gig-OS/gig)：构建用 overlay
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig)：图形安装器配置
- [Gig-OS/gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra)：自动构建与发布
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror)：下载站 iso.gentoozh.org
