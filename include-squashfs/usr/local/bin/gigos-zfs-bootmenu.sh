#!/bin/bash
# 由 Calamares shellprocess@zfs 在目标 chroot 内调用，为 ZFS 根安装 ZFSBootMenu（UEFI）。
# 其余文件系统不做任何事。序列位置与前置模块见 calamares-settings-gig 的 settings.conf。
# ZFS 根不用 GRUB:GRUB 按 feature-flag 白名单读池，新池特性尤其是原生加密会被它拒读，装好的系统
# 无法开机。本步接在 bootloader 之后，拆除 GRUB 在 ESP 与 NVRAM 的引导物再装 ZBM，使最终生效的是
# ZBM。非 ZFS 安装仍走 GRUB。

set -u

# 任何退出路径都自删，否则脚本残留进装好的系统。
trap 'rm -f "$0" 2>/dev/null || true' EXIT

# 脚本在目标 chroot 内，findmnt 看到的 / 即装好系统的根。
if ! findmnt -no FSTYPE / 2>/dev/null | grep -qx zfs; then
    echo "[gigos-zbm] 根文件系统非 ZFS,跳过 ZFSBootMenu 配置"
    exit 0
fi

# 根挂载源形如 zpcala/ROOT/distro/root。
ROOTDS=$(findmnt -no SOURCE / 2>/dev/null)
POOL=${ROOTDS%%/*}
if [ -z "${POOL}" ] || [ "${POOL}" = "${ROOTDS}" ]; then
    echo "[gigos-zbm] 致命：无法从根挂载源(${ROOTDS})解析池名，中止"
    exit 1
fi
echo "[gigos-zbm] ZFS 根:pool=${POOL} rootds=${ROOTDS}"

# 还原 shellprocess@zfspre 中和掉的 grub 工具:bootloader 模块已执行完，此处还原，
# 装好的系统不留被改过的系统二进制。
for r in /usr/sbin/grub-install.gigos-real /usr/bin/grub-install.gigos-real \
         /usr/sbin/grub-mkconfig.gigos-real /usr/bin/grub-mkconfig.gigos-real; do
    [ -e "$r" ] && mv -f "$r" "${r%.gigos-real}" && echo "[gigos-zbm] 已还原 ${r%.gigos-real}"
done

ESP_DIR=/boot/efi
if ! findmnt -no TARGET "${ESP_DIR}" >/dev/null 2>&1; then
    echo "[gigos-zbm] 致命：未发现挂载于 ${ESP_DIR} 的 ESP(ZFS 根仅支持 UEFI 安装),中止"
    exit 1
fi
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "[gigos-zbm] 致命：非 UEFI 引导环境(无 efivars),ZFSBootMenu 仅支持 UEFI,中止"
    exit 1
fi

# hostid 必须与建池时一致。zfshostid 模块通常已拷好，缺失时由 zgenhostid 补建，
# 它不覆盖已存在的文件，重复执行安全。
command -v zgenhostid >/dev/null 2>&1 && zgenhostid 2>/dev/null || true
[ -s /etc/hostid ] || { echo "[gigos-zbm] 致命：目标缺 /etc/hostid,首启将无法 import 池，中止"; exit 1; }

# 原生加密保留 ZfsJob 设的 keyformat=passphrase 与 keylocation=prompt，由 ZBM 提示口令。
# 不能改成 raw keyfile:keyfile 会落在加密根内，ZBM 解锁前无法读取，raw 又无法在 ZBM 处提示输入，
# 结果是无法解开加密根。代价是目标 initramfs 可能再提示一次口令，不阻塞引导。

# 不烘焙 zpool.cache:Calamares 的 mount 模块以 altroot（`-R /`）导入，写出的 cache 记录的是
# altroot 上下文，烘进目标 initramfs 后首启可能卡住或失配。只烘焙 hostid，首启靠 hostid 加
# import-scan，并启用 zfs-import-scan.service 兜底。
mkdir -p /etc/dracut.conf.d
{
    echo "# 由 gig-os 安装器(gigos-zfs-bootmenu.sh)写入：把 hostid 嵌入目标 initramfs。"
    echo "# hostid 必须与建池 hostid 一致，否则首启 zpool import 因 hostid 不符而失败。"
    echo "# 不烘 zpool.cache:它在 Calamares 的 altroot(-R /)导入下生成，可能污染；改用 import-scan。"
    echo 'add_dracutmodules+=" zfs "'
    echo 'install_items+=" /etc/hostid "'
} > /etc/dracut.conf.d/10-zfs-hostid.conf

systemctl enable zfs-import-scan.service zfs-mount.service zfs-zed.service zfs.target zfs-import.target 2>/dev/null || \
    echo "[gigos-zbm] 警告：部分 zfs systemd 单元 enable 失败(将依赖 preset),继续"

# 供 ZBM 读取的池属性:bootfs 指向引导环境，commandline 是 ZBM kexec 时附加的内核 cmdline。
zpool set bootfs="${ROOTDS}" "${POOL}" 2>/dev/null || echo "[gigos-zbm] 警告：设 bootfs 失败，继续"
# dist-kernel 加 dracut 无需显式 `root=`，由 ZBM 注入。此处不放任何密钥。
zfs set org.zfsbootmenu:commandline="rw quiet" "${ROOTDS}" 2>/dev/null || true

# 重建目标 initramfs 纳入上面的 hostid，必须在 generate-zbm 之前。两者都用 dracut，
# 但读的配置目录不同：目标读 /etc/dracut.conf.d，ZBM 读 /etc/zfsbootmenu/dracut.conf.d。
command -v dracut >/dev/null 2>&1 && dracut --force --regenerate-all || \
    echo "[gigos-zbm] 警告:dracut 重建失败，首启可能需在 ZBM 手动 import"

# sys-boot/zfsbootmenu 只装 perl 脚本与 generate-zbm，不预装 *.EFI，必须现场生成。
# 单文件 EFI 需要 sys-apps/systemd[boot] 的 linuxx64.efi.stub 与 `EFI.Enabled: true`。
# config.yaml 必须在此就地写，不能经 include-squashfs 投放：包自带的那份默认 `EFI.Enabled: false`
# 会覆盖投放的文件，结果只产出 Components 散件而无单文件 EFI，ZFS 根无法开机。
mkdir -p /etc/zfsbootmenu/dracut.conf.d /etc/zfsbootmenu/generate-zbm.pre.d /etc/zfsbootmenu/generate-zbm.post.d
# ZBM 镜像用自己的 dracut 配置目录，上面写给目标系统的那份对它无效。此处不装一份 /etc/hostid，
# ZBM 镜像内的 SPL hostid 就与建池时不一致，zpool import 被拒绝，开机落进紧急 shell。
cat > /etc/zfsbootmenu/dracut.conf.d/10-hostid.conf <<'ZBMHOSTID'
# 由 gig-os 安装器写入：把建池时的 hostid 一并嵌入 ZFSBootMenu 镜像，使其能导入本机的池。
install_items+=" /etc/hostid "
ZBMHOSTID
cat > /etc/zfsbootmenu/config.yaml <<'ZBMCFG'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PreHooksDir: /etc/zfsbootmenu/generate-zbm.pre.d
  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d
Components:
  ImageDir: /boot/efi/EFI/zbm
  Versions: 3
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/zbm
  Stub: /usr/lib/systemd/boot/efi/linuxx64.efi.stub
  Versions: false
  Enabled: true
Kernel:
  CommandLine: ro quiet loglevel=0 zbm.import_policy=hostid zbm.prefer=@@POOL@@
ZBMCFG
# heredoc 不展开变量，池名在此替换。`zbm.prefer` 让 ZBM 优先导入本机的池；
# `zbm.import_policy=hostid` 允许 hostid 不匹配时改用池记录的 hostid 再导入。
sed -i "s|@@POOL@@|${POOL}|" /etc/zfsbootmenu/config.yaml
ZBM_EFI=""
if command -v generate-zbm >/dev/null 2>&1; then
    mkdir -p "${ESP_DIR}/EFI/zbm"
    generate-zbm 2>&1 | sed 's/^/[gigos-zbm][generate-zbm] /' || \
        echo "[gigos-zbm] 警告:generate-zbm 返回非零，检查生成物是否仍产出"
    for cand in "${ESP_DIR}"/EFI/zbm/vmlinuz.EFI "${ESP_DIR}"/EFI/zbm/*.EFI; do
        [ -f "${cand}" ] && { ZBM_EFI="${cand}"; break; }
    done
else
    echo "[gigos-zbm] 致命：目标缺 generate-zbm(Live-ISO 是否漏装 sys-boot/zfsbootmenu?),中止"
    exit 1
fi
[ -n "${ZBM_EFI}" ] || { echo "[gigos-zbm] 致命:generate-zbm 未产出 *.EFI(缺 EFI stub?config EFI.Enabled?),中止"; exit 1; }
echo "[gigos-zbm] ZBM EFI 已生成：${ZBM_EFI}"

# 拆除 GRUB。bootloader.conf 的 `installEFIFallback: true` 已让 GRUB 写进 ESP 的
# EFI/BOOT/BOOTX64.EFI 与 EFI/<entry>/grubx64.efi 并建了 NVRAM 项，而 GRUB 无法读取本池，
# 固件走 fallback 或选到 GRUB 项就落进 grub rescue。以下三步必须按序执行，最后写入者生效。
# 1. 删 ESP 上含 grubx64.efi 的 EFI 子目录
for grubdir in "${ESP_DIR}"/EFI/*/; do
    if [ -f "${grubdir}grubx64.efi" ] || [ -f "${grubdir}grubx64.EFI" ]; then
        echo "[gigos-zbm] 删除 ESP 上的 GRUB 目录：${grubdir}"
        rm -rf "${grubdir}"
    fi
done
# 2. 删除指向 grubx64.efi 的 NVRAM 项。按 loader 路径反查，不依赖引导项名称。
if command -v efibootmgr >/dev/null 2>&1; then
    for n in $(efibootmgr -v 2>/dev/null | grep -iE 'File\(.*grubx64\.efi' | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p'); do
        echo "[gigos-zbm] 删除 GRUB NVRAM 引导项 Boot${n}"
        efibootmgr -B -b "${n}" >/dev/null 2>&1 || true
    done
    # 删旧的同名 ZBM 项，使重装幂等
    for n in $(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\?[[:space:]]*ZFSBootMenu$/\1/p'); do
        efibootmgr -B -b "${n}" >/dev/null 2>&1 || true
    done
fi

# 3. 装 ZBM 到固定路径与 fallback，盖过 GRUB 的 BOOTX64.EFI
install -D -m0644 "${ZBM_EFI}" "${ESP_DIR}/EFI/zbm/vmlinuz.EFI"
install -D -m0644 "${ZBM_EFI}" "${ESP_DIR}/EFI/BOOT/BOOTX64.EFI"

# 建 ZBM 的 UEFI 引导项并置于 BootOrder 之首。ESP 磁盘与分区号由挂载源反推。
ESP_DEV=$(findmnt -no SOURCE "${ESP_DIR}")
ESP_DISK=$(lsblk -no PKNAME "${ESP_DEV}" 2>/dev/null | head -1)
ESP_PART=$(lsblk -no PARTN "${ESP_DEV}" 2>/dev/null | head -1)
[ -z "${ESP_PART}" ] && ESP_PART=$(printf '%s' "${ESP_DEV}" | grep -oE '[0-9]+$')
if command -v efibootmgr >/dev/null 2>&1 && [ -n "${ESP_DISK}" ] && [ -n "${ESP_PART}" ]; then
    efibootmgr -c -d "/dev/${ESP_DISK}" -p "${ESP_PART}" -L "ZFSBootMenu" -l '\EFI\zbm\vmlinuz.EFI' >/dev/null 2>&1 \
        || echo "[gigos-zbm] 警告:efibootmgr 建项失败，已装回退 EFI/BOOT/BOOTX64.EFI,固件应仍可引导"
else
    echo "[gigos-zbm] 警告：无法解析 ESP 磁盘/分区号(dev=${ESP_DEV})或缺 efibootmgr;靠回退 EFI/BOOT/BOOTX64.EFI 引导"
fi

echo "[gigos-zbm] ZFSBootMenu 配置完成:hostid 已入 initramfs、GRUB 引导物已清、ZBM EFI 已装并置首、bootfs=${ROOTDS}"

rm -f "$0" 2>/dev/null || true
exit 0
