#!/bin/bash
# gigos-zfs-bootmenu.sh — 装机后(Calamares shellprocess@zfs,目标 chroot 内,dontChroot:false → ROOT=/)
# 给 ZFS-root 安装装上 ZFSBootMenu(UEFI)并修开机三大坑。仅 ZFS 根触发,其余文件系统 no-op。
#
# 为什么不用 GRUB:GRUB 的 ZFS 读取依赖 feature-flag 白名单,新池特性(尤其原生加密)会让
#   GRUB 拒读 → 装好的系统开不了机。决策(多发行版调研后已定):ZFS 根一律走 ZFSBootMenu,
#   ext4/xfs/btrfs/LUKS 仍走 GRUB。settings.conf 里 grubcfg/bootloader 仍在序列(为非 ZFS 安装),
#   但本步【接在 bootloader 之后】:ZFS 根时主动拆掉 GRUB 在 ESP/NVRAM 留下的引导物、再装 ZBM,
#   保证最终固件跑的是 ZBM 而非读不了池的 GRUB(见下「拆 GRUB」段——修复 fallback 互踩)。
#
# 整体顺序(被 Calamares 调用时,前置模块已完成):partition 写 zfsInfo → zfs(ZfsJob)建池/数据集
#   并在 live 跑 zgenhostid → unpackfs 解包 → mount 以 -R 重导入池(+加密时 load-key)→ fstab(跳过 zfs)→
#   zfshostid 把 live 的 /etc/hostid 拷进目标 → grubcfg/bootloader(给非 ZFS;ZFS 根产物在此被本步清掉)
#   → 本脚本(shellprocess@zfs)。
#
# 本脚本干官方 Calamares 模块做不了的事,每件都对应一个 ZFS 开机失败坑:
#   ① hostid:zpool 记住建池时的 hostid;目标必须用同一 hostid 才能 import。zfshostid 已拷 hostid,
#      仍显式校验/补建,并把 /etc/hostid 注入目标 initramfs(dracut install_items),否则首启 import 失败。
#   ② 首启导入靠 hostid + import-scan(不烘焙可能受 altroot 污染的 zpool.cache;见下「cache」段)。
#   ③ 原生加密:把根改成 keyfile 解锁(keyfile 只进【目标 initramfs】,不进 ZBM),并让 ZBM 仍在菜单
#      处提示一次口令(keysource)——避免 ZBM 解锁后目标 initramfs 再问一次的双重提示。
#   ④ ZFSBootMenu EFI:用 generate-zbm 生成单文件 UEFI 可执行、装进 ESP、efibootmgr 建项、置 bootfs。
# 一次性安装器助手,执行后自删,不进装好的系统。

set -u

# 一次性安装器助手:任何退出路径(含非 ZFS 安装的提前 exit、出错 exit)都自删,绝不残留进装好系统。
# (旧版 rm 只在 ZFS 成功路径末尾;非 ZFS 提前 exit 会泄漏脚本 → verify-iso 0c 拦截。trap 根治。)
trap 'rm -f "$0" 2>/dev/null || true' EXIT

# ── 探针(gating,镜像 shellprocess@nvidia / gigos-fix-crypttab 风格)──
# 非 ZFS 根直接退出 0,本步对 ext4/xfs/btrfs/LUKS 安装彻底 no-op。
# findmnt 看目标根(本脚本在目标 chroot 内 → / 即装好系统的根)。
if ! findmnt -no FSTYPE / 2>/dev/null | grep -qx zfs; then
    echo "[gigos-zbm] 根文件系统非 ZFS,跳过 ZFSBootMenu 配置"
    exit 0
fi

# 取根数据集与池名(根挂载源形如 zpcala/ROOT/distro/root)
ROOTDS=$(findmnt -no SOURCE / 2>/dev/null)
POOL=${ROOTDS%%/*}
if [ -z "${POOL}" ] || [ "${POOL}" = "${ROOTDS}" ]; then
    echo "[gigos-zbm] 致命:无法从根挂载源(${ROOTDS})解析池名,中止"
    exit 1
fi
echo "[gigos-zbm] ZFS 根:pool=${POOL} rootds=${ROOTDS}"

# ── 恢复被 gigos-zfs-prebootloader.sh 中和的 grub 工具 ──
# 前置步骤(shellprocess@zfspre)为让 Calamares 的 grubcfg/bootloader 模块不在 ZFS 上致命失败,
# 把 grub-install/grub-mkconfig 临时换成 no-op(挪到 .gigos-real)。本步在 bootloader 之后跑,
# 把它们还原,使装好的系统保留正常的 grub 工具(ZFS 系统虽走 ZBM,但不留改过的系统二进制更干净)。
for r in /usr/sbin/grub-install.gigos-real /usr/bin/grub-install.gigos-real \
         /usr/sbin/grub-mkconfig.gigos-real /usr/bin/grub-mkconfig.gigos-real; do
    [ -e "$r" ] && mv -f "$r" "${r%.gigos-real}" && echo "[gigos-zbm] 已还原 ${r%.gigos-real}"
done

ESP_DIR=/boot/efi
if ! findmnt -no TARGET "${ESP_DIR}" >/dev/null 2>&1; then
    echo "[gigos-zbm] 致命:未发现挂载于 ${ESP_DIR} 的 ESP(ZFS 根仅支持 UEFI 安装),中止"
    exit 1
fi
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "[gigos-zbm] 致命:非 UEFI 引导环境(无 efivars),ZFSBootMenu 仅支持 UEFI,中止"
    exit 1
fi

# ── ① hostid:确保目标 /etc/hostid 存在(zfshostid 模块通常已拷),并与池匹配 ──
# 池在 live 由 ZfsJob 的 zgenhostid 建池;zfshostid 已把 live /etc/hostid 拷进目标。
# 若缺失,用 zgenhostid 补建(plain zgenhostid 不覆盖已存在文件 → 幂等安全)。
command -v zgenhostid >/dev/null 2>&1 && zgenhostid 2>/dev/null || true
[ -s /etc/hostid ] || { echo "[gigos-zbm] 致命:目标缺 /etc/hostid,首启将无法 import 池,中止"; exit 1; }

# ── ③ 原生加密:保留 keyformat=passphrase + keylocation=prompt(ZfsJob 勾选加密时所设)──
# 由 ZFSBootMenu 在菜单处提示口令解锁。QEMU 实测:ZBM 能导入加密池、解锁、kexec 一路进 KDE 桌面。
# 【不要】像旧版那样 change-key 成 raw keyfile:那样 keyfile 落在加密根内、ZBM 解锁前读不到,raw 又无法
# 在 ZBM 处提示输入 → ZBM 根本解不开加密根、开不了机(已实测会炸)。保留 passphrase 让 ZBM 直接 prompt
# 才是可行解。(若目标 initramfs 出现第二次口令提示,属可接受的小瑕疵;实测本路径未阻塞引导。)
ZFS_KEYFILE=""

# ── ② zpool.cache:不烘焙(避免 altroot 污染),改用 hostid + import-scan ──
# Calamares mount 模块以 `zpool import -N -R /`(altroot)导入池;此时 `zpool set cachefile` 写出的
# cache 记录的是 altroot 导入上下文,烘进目标 initramfs 后首启 zfs-import-cache 可能卡/失配。
# 决策:目标 initramfs 只烘 hostid,不烘 cache;首启用 hostid 匹配 + import-by-scan(单盘目标稳妥)。
# 目标系统侧同时启用 zfs-import-scan.service 作兜底,使缺/旧 cache 不致让 zfs-import.target 卡住。
mkdir -p /etc/dracut.conf.d
{
    echo "# 由 gig-os 安装器(gigos-zfs-bootmenu.sh)写入:把 hostid 嵌入目标 initramfs。"
    echo "# hostid 必须与建池 hostid 一致,否则首启 zpool import 因 hostid 不符而失败。"
    echo "# 不烘 zpool.cache:它在 Calamares 的 altroot(-R /)导入下生成,可能污染;改用 import-scan。"
    echo 'add_dracutmodules+=" zfs "'
    if [ -n "${ZFS_KEYFILE}" ]; then
        echo "# 原生加密 keyfile:仅嵌入【目标】initramfs,使首启静默解锁、不二次提示口令(口令在 ZBM 输一次)。"
        echo "install_items+=\" /etc/hostid ${ZFS_KEYFILE} \""
    else
        echo 'install_items+=" /etc/hostid "'
    fi
} > /etc/dracut.conf.d/10-zfs-hostid.conf

# ── ZFS systemd 服务:目标系统开机自动导入(cache + scan 双保险)/挂载/ZED ──
systemctl enable zfs-import-scan.service zfs-mount.service zfs-zed.service zfs.target zfs-import.target 2>/dev/null || \
    echo "[gigos-zbm] 警告:部分 zfs systemd 单元 enable 失败(将依赖 preset),继续"

# ── 池属性:供 ZFSBootMenu 读取(bootfs 指向引导环境,commandline 传内核 cmdline)──
zpool set bootfs="${ROOTDS}" "${POOL}" 2>/dev/null || echo "[gigos-zbm] 警告:设 bootfs 失败,继续"
# commandline 是 ZBM kexec 进内核时附加的 cmdline。dist-kernel + dracut 不需要显式 root=(ZBM 注入);
# 加密由 keyfile 在目标 initramfs 静默处理,不在此放任何密钥。
zfs set org.zfsbootmenu:commandline="rw quiet" "${ROOTDS}" 2>/dev/null || true

# ── 重建目标 initramfs,纳入上面的 hostid/keyfile 配置 ──
# dist-kernel:dracut --regenerate-all 覆盖所有已装内核;含可能的 keyfile 故给足超时(见 .conf timeout)。
# 必须在 generate-zbm 之前:ZBM 也用 dracut 生成自己的镜像,但 ZBM 镜像【不】含目标 keyfile(keyfile
# 只在目标 /etc/dracut.conf.d,ZBM 用自己的 /etc/zfsbootmenu/dracut.conf.d),互不污染。
command -v dracut >/dev/null 2>&1 && dracut --force --regenerate-all || \
    echo "[gigos-zbm] 警告:dracut 重建失败,首启可能需在 ZBM 手动 import"

# ── ④ ZFSBootMenu EFI:generate-zbm 生成单文件 UEFI 可执行,装进 ESP ──
# guru 的 sys-boot/zfsbootmenu 不预装 *.EFI(只装 perl 脚本 + generate-zbm),故必须现场生成。
# 单文件 EFI 需 EFI stub(linuxx64.efi.stub,来自 sys-apps/systemd[boot])与 EFI.Enabled:true 的 config。
# 【关键】这里在目标内【就地写】config.yaml:不靠 include-squashfs 投放——那个会和 sys-boot/zfsbootmenu
# 包自带的 /etc/zfsbootmenu/config.yaml(EFI.Enabled:false 默认)冲突、被包覆盖 → 只出 Components 散件、
# 无单文件 EFI → ZFS 根开不了机(实测冲突包默认版会赢)。在此(generate-zbm 之前)落地为准,杜绝冲突。
mkdir -p /etc/zfsbootmenu/dracut.conf.d /etc/zfsbootmenu/generate-zbm.pre.d /etc/zfsbootmenu/generate-zbm.post.d
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
  CommandLine: ro quiet loglevel=0
ZBMCFG
ZBM_EFI=""
if command -v generate-zbm >/dev/null 2>&1; then
    mkdir -p "${ESP_DIR}/EFI/zbm"
    generate-zbm 2>&1 | sed 's/^/[gigos-zbm][generate-zbm] /' || \
        echo "[gigos-zbm] 警告:generate-zbm 返回非零,检查生成物是否仍产出"
    for cand in "${ESP_DIR}"/EFI/zbm/vmlinuz.EFI "${ESP_DIR}"/EFI/zbm/*.EFI; do
        [ -f "${cand}" ] && { ZBM_EFI="${cand}"; break; }
    done
else
    echo "[gigos-zbm] 致命:目标缺 generate-zbm(Live-ISO 是否漏装 sys-boot/zfsbootmenu?),中止"
    exit 1
fi
[ -n "${ZBM_EFI}" ] || { echo "[gigos-zbm] 致命:generate-zbm 未产出 *.EFI(缺 EFI stub?config EFI.Enabled?),中止"; exit 1; }
echo "[gigos-zbm] ZBM EFI 已生成:${ZBM_EFI}"

# ── 拆 GRUB:修复 fallback 互踩 + 不留读不了池的 GRUB 引导项 ──
# bootloader.conf installEFIFallback:true → 前面的 GRUB bootloader 模块已把 GRUB 写进
# ESP 的 EFI/BOOT/BOOTX64.EFI 和 EFI/<entry>/grubx64.efi,并建了 GRUB NVRAM 项。GRUB 读不了
# 本 ZFS 池(正是改用 ZBM 的原因),若固件走 fallback 或选到 GRUB 项 → grub rescue。本步在
# bootloader 之后跑,主动:① 删 ESP 里含 grubx64.efi 的 GRUB 目录;② 删 GRUB NVRAM 项
# (按 loader 路径 \EFI\*\grubx64.efi 反查,不依赖人类可读名 ${NAME});③ 最后把 ZBM 写成
# fallback BOOTX64.EFI(最后写者胜)。
# ① 删 ESP 里的 GRUB 目录(任何含 grubx64.efi 的 EFI 子目录)
for grubdir in "${ESP_DIR}"/EFI/*/; do
    if [ -f "${grubdir}grubx64.efi" ] || [ -f "${grubdir}grubx64.EFI" ]; then
        echo "[gigos-zbm] 删除 ESP 上的 GRUB 目录:${grubdir}"
        rm -rf "${grubdir}"
    fi
done
# ② 删指向 grubx64.efi 的 GRUB NVRAM 引导项(用 -v 输出里的 File 路径匹配,大小写无关)
if command -v efibootmgr >/dev/null 2>&1; then
    for n in $(efibootmgr -v 2>/dev/null | grep -iE 'File\(.*grubx64\.efi' | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p'); do
        echo "[gigos-zbm] 删除 GRUB NVRAM 引导项 Boot${n}"
        efibootmgr -B -b "${n}" >/dev/null 2>&1 || true
    done
    # 删旧的同名 ZFSBootMenu 项(幂等重装)
    for n in $(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\?[[:space:]]*ZFSBootMenu$/\1/p'); do
        efibootmgr -B -b "${n}" >/dev/null 2>&1 || true
    done
fi

# ③ 安装 ZBM 到固定路径 + fallback(最后写,盖过 GRUB 的 BOOTX64.EFI)
install -D -m0644 "${ZBM_EFI}" "${ESP_DIR}/EFI/zbm/vmlinuz.EFI"
install -D -m0644 "${ZBM_EFI}" "${ESP_DIR}/EFI/BOOT/BOOTX64.EFI"

# 建 ZBM 的 UEFI 引导项并置于 BootOrder 之首(-c 默认即前插)。ESP 磁盘/分区号由挂载源反推。
ESP_DEV=$(findmnt -no SOURCE "${ESP_DIR}")
ESP_DISK=$(lsblk -no PKNAME "${ESP_DEV}" 2>/dev/null | head -1)
ESP_PART=$(lsblk -no PARTN "${ESP_DEV}" 2>/dev/null | head -1)
[ -z "${ESP_PART}" ] && ESP_PART=$(printf '%s' "${ESP_DEV}" | grep -oE '[0-9]+$')
if command -v efibootmgr >/dev/null 2>&1 && [ -n "${ESP_DISK}" ] && [ -n "${ESP_PART}" ]; then
    efibootmgr -c -d "/dev/${ESP_DISK}" -p "${ESP_PART}" -L "ZFSBootMenu" -l '\EFI\zbm\vmlinuz.EFI' >/dev/null 2>&1 \
        || echo "[gigos-zbm] 警告:efibootmgr 建项失败,已装回退 EFI/BOOT/BOOTX64.EFI,固件应仍可引导"
else
    echo "[gigos-zbm] 警告:无法解析 ESP 磁盘/分区号(dev=${ESP_DEV})或缺 efibootmgr;靠回退 EFI/BOOT/BOOTX64.EFI 引导"
fi

echo "[gigos-zbm] ZFSBootMenu 配置完成:hostid 已入 initramfs、GRUB 引导物已清、ZBM EFI 已装并置首、bootfs=${ROOTDS}"

# 一次性安装器助手,执行后自删,不进装好的系统
rm -f "$0" 2>/dev/null || true
exit 0
