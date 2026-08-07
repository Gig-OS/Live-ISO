#!/bin/bash
# 装机时在 Calamares 的 grubcfg 与 bootloader 模块之前执行（shellprocess@zfspre，目标 chroot 内，
# dontChroot:false → ROOT=/），仅 ZFS 根触发。
# ZFS 根安装时 bootloader 模块仍会执行 `grub-install`，但 GRUB 无法读取 ZFS 池（尤其是原生加密），
# grub-install 退出码 1 会让 bootloader 模块失败并使 Calamares 致命中止，装 ZFSBootMenu 的
# shellprocess@zfs 根本轮不到执行。
# 因此本步把 grub-install 与 grub-mkconfig 临时换成 no-op（原件挪到 *.gigos-real），让这两个模块以
# 成功状态空执行；真正的引导器由其后的 shellprocess@zfs 安装，并还原这两个工具。
# 非 ZFS 安装直接退出，grub 照常安装。
set -u
# 任何退出路径都自删，不残留进装好的系统
trap 'rm -f "$0" 2>/dev/null || true' EXIT

if ! findmnt -no FSTYPE / 2>/dev/null | grep -qx zfs; then
    echo "[gigos-zbm-pre] 根非 ZFS,跳过(grub 正常安装)"
    exit 0
fi
echo "[gigos-zbm-pre] ZFS 根：临时中和 grub-install/grub-mkconfig,使 bootloader 模块不致命失败(ZBM 接管引导)"

for t in grub-install grub-mkconfig; do
    r=$(command -v "$t" 2>/dev/null) || continue
    [ -e "${r}.gigos-real" ] && continue
    mv "$r" "${r}.gigos-real" || continue
    if [ "$t" = grub-install ]; then
        # grub-install 仅换成 no-op 不够:bootloader 模块执行完 grub-install 后会无条件把
        # grubx64.efi copy2 成回退的 bootx64.efi（installEFIFallback 默认开启），源文件不存在就抛
        # FileNotFoundError，而 Calamares 的 run() 只捕获 CalledProcessError。
        # 因此 stub 解析 --efi-directory、--bootloader-id、--target，在 bootloader 模块要复制的路径
        # 造一个空占位 grubx64.efi 让 copy2 通过。该占位无 NVRAM 项指向，不会被引导。
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
