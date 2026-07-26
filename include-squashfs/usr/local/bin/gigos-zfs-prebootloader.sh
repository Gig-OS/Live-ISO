#!/bin/bash
# gigos-zfs-prebootloader.sh — 装机时在 Calamares 的 grubcfg/bootloader 模块【之前】跑
# (shellprocess@zfspre,目标 chroot 内,dontChroot:false → ROOT=/)。仅 ZFS 根触发。
#
# 为什么需要:ZFS 根安装时,Calamares 的 bootloader 模块仍会跑 `grub-install`,但 GRUB 读不了
# ZFS 池(尤其原生加密)→ grub-install 退 1 → bootloader 模块失败 → Calamares 致命中止,
# 装机后处理(shellprocess@zfs,装 ZFSBootMenu)根本轮不到跑(实测就卡在这:安装失败/启动加载器安装出错)。
# 解法:本步把 grub-install / grub-mkconfig 临时换成 no-op(原件挪到 *.gigos-real),让 grubcfg/bootloader
# 模块「成功」地空跑过;真正的引导器(ZFSBootMenu)由其后的 shellprocess@zfs 安装,并把这两个工具还原。
# 非 ZFS 安装:探针直接退出,grub 照常安装,完全不受影响。
set -u
# 一次性安装器助手,任何退出路径都自删,不残留进装好系统
trap 'rm -f "$0" 2>/dev/null || true' EXIT

if ! findmnt -no FSTYPE / 2>/dev/null | grep -qx zfs; then
    echo "[gigos-zbm-pre] 根非 ZFS,跳过(grub 正常安装)"
    exit 0
fi
echo "[gigos-zbm-pre] ZFS 根:临时中和 grub-install/grub-mkconfig,使 bootloader 模块不致命失败(ZBM 接管引导)"

for t in grub-install grub-mkconfig; do
    r=$(command -v "$t" 2>/dev/null) || continue
    [ -e "${r}.gigos-real" ] && continue   # 幂等:已中和则跳过
    mv "$r" "${r}.gigos-real" || continue
    if [ "$t" = grub-install ]; then
        # grub-install:no-op 不够。Calamares bootloader 模块跑完 grub-install 后会【无条件】
        # copy2 grubx64.efi → 回退 bootx64.efi(installEFIFallback,默认开),源文件不在就
        # FileNotFoundError 崩(run() 只 catch CalledProcessError,catch 不到它)。故 stub 解析
        # --efi-directory/--bootloader-id/--target,在 bootloader 模块要 copy 的路径造个空占位
        # grubx64.efi 让 copy2 通过。真引导器 ZFSBootMenu 由其后的 shellprocess@zfs 安装,
        # 覆盖 bootx64.efi 并把 efibootmgr 置首;这个占位 grub EFI 无 NVRAM 项指向、永不被引导。
        cat > "$r" <<'GRUBSTUB'
#!/bin/sh
efidir=/boot/efi; blid=GRUB; tgt=x86_64-efi
for a in "$@"; do case "$a" in
  --efi-directory=*) efidir="${a#*=}" ;;
  --bootloader-id=*) blid="${a#*=}" ;;
  --target=*) tgt="${a#*=}" ;;
esac; done
case "$tgt" in i386-efi) g=grubia32.efi ;; arm64-efi) g=grubaa64.efi ;; *) g=grubx64.efi ;; esac
mkdir -p "${efidir}/EFI/${blid}" 2>/dev/null
: > "${efidir}/EFI/${blid}/${g}"
echo "[gigos-zbm-pre] grub-install no-op + 占位 ${efidir}/EFI/${blid}/${g}(ZBM 接管真引导)"
exit 0
GRUBSTUB
    else
        printf '#!/bin/sh\necho "[gigos-zbm-pre] %s 在 ZFS 安装中被中和(ZBM 接管引导);args: $*"\nexit 0\n' "$t" > "$r"
    fi
    chmod +x "$r"
    echo "[gigos-zbm-pre] 已中和 $t(原件 → ${r}.gigos-real,由 shellprocess@zfs 还原)"
done
exit 0
