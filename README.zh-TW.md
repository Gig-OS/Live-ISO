# Live-ISO

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Gig-OS Live ISO 的建置腳本。產物是 KDE Plasma 桌面 Live ISO（`gig-os-YYYYMMDD.iso`），預先配好中文環境、輸入法、字型與顯示卡驅動，可直接試用，也可用 Calamares 安裝到硬碟。

只想下載的話不需要本倉庫，到 [iso.gentoozh.org](https://iso.gentoozh.org/) 取最新一版即可。

## 環境需求

在 Gentoo 上以 root 執行。需要 bash、wget、tar、xz、git、make、m4、rsync、帶 xz 支援的 squashfs-tools，以及建置 arch-install-scripts 用的 asciidoc。

`arch-scripts` 是 git 子模組，複製時要一併取得：

```sh
git clone -b KDE --recurse-submodules https://github.com/Gig-OS/Live-ISO.git
```

**分支必須明確指定。** 上游的建置分支是 `KDE`，不是 `main`。

## 建置

```sh
sudo ./build.sh
```

`build.sh` 是唯一進入點，它持有 `/run/gigos-build.lock`，同一時刻只允許一鍋在執行。建置選項在 `config`，全部寫成 `: "${VAR:=預設值}"`，可以直接用環境變數覆寫而不改檔案：

```sh
sudo CORES=32 TMPFS=80G ./build.sh
```

常用項：`CORES` 與 `MAKEOPTS` 決定並行度；`TMPFS` 是建置用 tmpfs 大小，記憶體足夠時調大能顯著加快編譯；`MIRROR` 與 `GENTOO_MIRRORS` 指向 distfiles 來源。按本機需求改 `include-squashfs/etc/portage/make.conf/common`。

自動建置與發布在 [gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra)，本倉庫不含發布邏輯。

## 目錄

| 路徑 | 內容 |
|---|---|
| `build.sh` | 建置主腳本 |
| `config` | 建置選項、overlay 清單、額外套件 |
| `arch-scripts` | arch-chroot 系列腳本，git 子模組 |
| `hooks/` | 系統更新完成後依序執行的掛鉤 |
| `include-squashfs/` | 更新前複製進 squashfs 的檔案 |
| `include-iso/` | 複製到 ISO 根的檔案，含 GRUB 選單 |
| `exclude.txt` | 打包 squashfs 時排除的路徑 |

## overlay 與額外套件

`config` 的 `OVERLAYS` 定義要加的 overlay，`EXTRA_PKGS` 定義額外安裝的套件。目前用到三個 overlay：`gig` 提供 `calamares-settings-gig`，`gentoo-zh` 與 `guru` 提供 `flclash` 等非安裝必需的套件。

## 出廠清理

`hooks/99-sanitize-for-release.sh` 是發布前的閘門，在打包進 squashfs 之前執行。它刪除建置機專屬設定，包括 `zz-autounmask` 與 build-host 的 `make.conf` 調校，並強制檢查 Calamares 的安裝清理步驟存在。檢查未通過即中止建置，因為缺少該步驟會讓裝好的系統殘留 live 的免密設定。

被閘門攔下時，在日誌裡搜 `关键` 定位具體條目（標記在腳本裡是簡體，逐字保持不變）。

## ZFS 根與 ZFSBootMenu

Calamares 分割區頁可以選 ZFS 作根檔案系統。勾選加密時使用 ZFS 原生加密（aes-256-gcm），由 ZFSBootMenu 開機，因為 GRUB 讀不了帶新特性或原生加密的 ZFS 池。**口令至少 8 位**，這是 ZFS 原生加密的硬性要求，更短會讓 `zpool create` 失敗、安裝中止。

相關邏輯在 `include-squashfs/usr/local/bin/gigos-zfs-bootmenu.sh` 與 `gigos-zfs-prebootloader.sh`，由 Calamares 的 shellprocess 呼叫。

## 顯示卡驅動

開機選單提供開源 nouveau 與閉源 NVIDIA 兩條路徑。閉源模組未簽名，需要先在 BIOS 關閉 Secure Boot，否則核心拒絕載入，表現為黑畫面或卡住。驅動由 `gigos-nvidia-load.service` 在 sddm 啟動前正常 modprobe，不走 early KMS。

## 相關倉庫

- [Gig-OS/gig](https://github.com/Gig-OS/gig)：建置用 overlay
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig)：圖形安裝器設定
- [Gig-OS/gentoozh-liveiso-infra](https://github.com/Gig-OS/gentoozh-liveiso-infra)：自動建置與發布
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror)：下載站 iso.gentoozh.org
