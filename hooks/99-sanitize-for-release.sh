#!/bin/bash
# 出厂安全清理，由 build.sh 在 makesquashfs 之前 source 执行。
#
# 构建期写进系统树的构建机专属配置会原样发给用户：MAKEOPTS 的高并发会让小内存机
# 编译时 OOM，binpkg 缓存类调优也不该随 ISO 发出。本 hook 在打包前把系统树还原成
# 对普通用户安全的通用配置，幂等且与构建环境无关。

MC="${WORKDIR}/squashfs/etc/portage/make.conf"

# 1. MAKEOPTS 还原为字面量 -j4。
#    不能写 $(nproc)：portage 的 make.conf 解析器不支持命令替换，会报 bad substitution
#    且 MAKEOPTS 失效。按 CPU 自适应由 gigos-cpuflags.service 写进 make.conf.d/cpuflags，
#    字母序在 common 之后覆盖此值；-j4 只是服务未执行前的兜底。
if [ -f "${MC}/common" ]; then
    sed -i 's/^MAKEOPTS=.*/MAKEOPTS="-j4"/' "${MC}/common"
fi

# 2. 移除任何构建机专用的二进制包缓存调优（若构建包装层注入过）。
#    删整文件命中的 EMERGE_DEFAULT_OPTS / FEATURES 注入片段，再逐文件擦关键字。
rm -f "${MC}"/zz-buildhost
if [ -d "${MC}" ]; then
    grep -rlE 'buildpkg|--usepkg|--buildpkg|load-average=' "${MC}/" 2>/dev/null \
      | while read -r f; do
            sed -i -E 's/(--usepkg|--buildpkg|--load-average=[0-9]+)//g; s/[[:space:]]+buildpkg//g' "$f"
        done
fi

# 2.5 清掉 @world 的 --autounmask-continue 在构建期写的 zz-autounmask(USE / keyword / mask pin)。
#     CONFIG_PROTECT="-*" 下这些直接落进系统树，是构建期滚动树漂移的产物，不应随 ISO 发给用户。
PRT="${WORKDIR}/squashfs/etc/portage"
rm -f "${PRT}/package.use/zz-autounmask" "${PRT}/package.accept_keywords/zz-autounmask" \
      "${PRT}/package.mask/zz-autounmask" "${PRT}/package.license/zz-autounmask" 2>/dev/null || true

# 3. CPU_FLAGS_X86 不能留构建机的固定值。
#    Calamares 把 live squashfs 整盘复制到用户硬盘，这里的 make.conf 会原样成为用户
#    系统的配置。留下构建机的标志位而用户 CPU 不支持时，后续 emerge 编译出的包会在
#    运行时 SIGILL。出厂写 x86-64-v3 基线并加 gigos-auto-cpuflags 标记，
#    gigos-cpuflags.service 每次启动按真机 CPU 覆盖，用户删标记即停。
#    先清掉其它文件里可能残留的值，再把 cpuflags 归一成标记加基线。
for f in "${MC}"/common "${MC}"/cpuflags.conf; do
    [ -f "$f" ] && sed -i '/^CPU_FLAGS_X86=/d' "$f"
done
cat > "${MC}/cpuflags" <<'CPUF'
# gigos-auto-cpuflags
# 由 gigos-cpuflags 按本机 CPU 自动生成；删除上面这行标记即停止自动覆盖，可改成自己的值。
# 下面是出厂安全基线(x86-64-v3,2013+/AVX2);开机后 gigos-cpuflags.service 按真机 CPU 覆盖。
CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 ssse3"
CPUF

# 4. GENTOO_MIRRORS 写带标记的海外基线，开机后由 gigos-mirror.service 按出口 IP 国家码
#    改成就近镜像，无法取得国家码时再按系统语言，机制与 gigos-cpuflags 相同。
#    标记表示这是自动值，用户删掉即固定。与构建时用的源无关。
{
    echo '# gigos-auto-mirror'
    echo '# 出厂基线是海外源，开机后 gigos-mirror.service 按出口 IP 或系统语言覆盖。删除本行标记即停止自动覆盖。'
    echo 'GENTOO_MIRRORS="https://distfiles.gentoo.org/ https://gentoo.osuosl.org/ https://ftp.fau.de/gentoo/"'
} > "${MC}/mirror"

# 出厂不带 gigos-mirror 运行期生成的 repos.conf 覆盖文件。它按开机时判定的地区写，
# 烘进 ISO 会把构建机所在地区的源发给所有人，且首启前就带上无从核对的地址。
rm -f "${WORKDIR}/squashfs/etc/portage/repos.conf/zz-gigos-mirror.conf" \
      "${WORKDIR}/squashfs/etc/portage/binrepos.conf/gentoo-zh.conf"

# 5. 解除 nvidia.conf 对 nouveau 的静态黑名单。
#    nvidia-drivers 自带的 /etc/modprobe.d/nvidia.conf 首行 `blacklist nouveau` 会让整个
#    系统永远用不了 nouveau，与默认 nouveau、选闭源项才上 nvidia 的双驱动设计冲突。
#    出厂注释掉这两行，改由 grub 内核参数切换：默认项不加 blacklist 走 nouveau，
#    闭源项用 cmdline 的 modprobe.blacklist=nouveau 让 nvidia 接管。
NVCONF="${WORKDIR}/squashfs/etc/modprobe.d/nvidia.conf"
if [ -f "${NVCONF}" ]; then
    sed -i 's/^blacklist nouveau/#blacklist nouveau/; s/^blacklist nova_core/#blacklist nova_core/' "${NVCONF}"
fi

# 6. 兜底清空二进制包 / 源码缓存（exclude.txt 也会排除，这里双保险；
#    用 find -delete 而非 glob，空目录/不同 shell 下都可靠）。
for d in binpkgs distfiles; do
    _cachedir="${WORKDIR}/squashfs/var/cache/${d}"
    # 因为构建机把宿主的持久缓存 bind 挂载到了这两个目录，此时直接删会穿过 bind 把宿主缓存一起删掉，
    # 下一锅只能从零编译(实测宿主 binpkg 缓存每锅后都被清空，冷构建要七个多小时)。
    # squashfs 已由 exclude.txt 排除这两个目录，挂载状态下跳过不影响出厂结果。
    if mountpoint -q "${_cachedir}" 2>/dev/null; then
        echo "[99-sanitize] ${d} 是 bind 挂载的宿主缓存，跳过清理(exclude.txt 已排除，不会进 ISO)"
        continue
    fi
    find "${_cachedir}" -mindepth 1 -delete 2>/dev/null || true
done
unset _cachedir

# 7. 安全断言：装机后清理 live 残留(autologin / SSH 密码登录 / 桌面调试按钮 / polkit 免密)全靠
#    calamares-settings-gig 的 shellprocess。打包前在此强校验契约确已接通，否则一旦指向 fork 失败
#    或被上游覆盖，会出装好后仍残留 autologin 与 SSH 密码登录的后门盘。任一缺失即中止，不出后门盘。
CSGSP="${WORKDIR}/squashfs/etc/calamares/modules/shellprocess.conf"
CSGSET="${WORKDIR}/squashfs/etc/calamares/settings.conf"
for pat in "sddm.conf.d/kde_settings.conf" "49-calamares-nopasswd.rules" "00-gigos-passwordlogin.conf" "gigos-nosleep.desktop" "gigos-sudo-nopasswd.desktop"; do
    grep -q "${pat}" "${CSGSP}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares 装机清理缺 ${pat} → 装好系统会残留 live 后门，中止"; exit 1; }
done
grep -qE '^[[:space:]]*-[[:space:]]*shellprocess[[:space:]]*$' "${CSGSET}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares settings.conf 未启用 shellprocess 清理步骤(清理不会跑)→ 中止"; exit 1; }
echo "[99-sanitize] 安全断言通过：装机清理契约已接(autologin / SSH 密码登录 / polkit 残留会被 calamares 删除)"

# 7.5 settings.conf 排的每个模块,calamares 里都得真有。calamares 大版本会增删模块(3.3→3.4 就换过一轮),
#      而 settings 是我们 fork 自己维护的：一旦排了个新版没有的模块，构建期一切正常、装机跑到那步才炸。
#      这里在出锅前静态比对 `settings.conf` 的 sequence 与已装的 calamares 模块目录，不匹配就中止。
CALMODDIR=""
for d in "${WORKDIR}/squashfs"/usr/lib64/calamares/modules "${WORKDIR}/squashfs"/usr/lib/calamares/modules; do
    [ -d "${d}" ] && { CALMODDIR="${d}"; break; }
done
if [ -f "${CSGSET}" ] && [ -n "${CALMODDIR}" ]; then
    MISSMOD=""
    # 只取 sequence 段里形如 `- 模块名` 的整行(排除 instances 段的 `- id: xxx`,那种带冒号);
    # shellprocess@nvidia 这类实例回落到基础模块名。
    for m in $(sed -n '/^sequence:/,/^[a-z]/p' "${CSGSET}" 2>/dev/null \
               | grep -oE '^[[:space:]]*-[[:space:]]*[a-z0-9@_.-]+[[:space:]]*$' \
               | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*$//; s/@.*//' | sort -u); do
        [ -d "${CALMODDIR}/${m}" ] || ls "${CALMODDIR}/${m}".* >/dev/null 2>&1 || MISSMOD="${MISSMOD} ${m}"
    done
    [ -z "${MISSMOD}" ] \
        || { echo "[99-sanitize] 致命:settings.conf 排了 calamares 里不存在的模块：${MISSMOD} → 装机跑到该步会炸，中止(calamares 升过大版本？对照 ${CALMODDIR##*/squashfs})"; exit 1; }
    echo "[99-sanitize] 安全断言通过:settings.conf 的模块在本锅 calamares 中全部存在"
else
    echo "[99-sanitize] 提示：未找到 calamares 模块目录或 settings.conf,跳过模块比对"
fi

# 8. ZFS 根装机契约断言。只在本锅确实安装了 generate-zbm 时强校验，这样 --keep-going 下
#    zfsbootmenu 被跳过时非 ZFS 盘照常出。装了 ZBM 就必须保证装机后处理脚本在位、
#    settings 已接 shellprocess@zfs、config 启用单文件 EFI，任一缺失即中止，
#    否则 ZFS 根会装出不可启动盘。
SQROOT="${WORKDIR}/squashfs"
if [ -x "${SQROOT}/usr/bin/generate-zbm" ] || [ -x "${SQROOT}/usr/sbin/generate-zbm" ]; then
    test -x "${SQROOT}/usr/local/bin/gigos-zfs-bootmenu.sh" \
        || { echo "[99-sanitize] 致命：装了 ZBM 却缺 gigos-zfs-bootmenu.sh → ZFS 根装机无引导器，中止"; exit 1; }
    grep -qE '^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$' "${CSGSET}" 2>/dev/null \
        || { echo "[99-sanitize] 致命:settings.conf 未接 shellprocess@zfs → ZFS 根装机不会装 ZBM,中止"; exit 1; }
    # shellprocess@zfs 必须接在 bootloader 之后(否则 GRUB 的 fallback EFI 会盖过 ZBM)
    awk '/^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$/{b=NR} /^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$/{z=NR} END{exit !(b&&z&&z>b)}' "${CSGSET}" \
        || { echo "[99-sanitize] 致命:settings.conf 中 shellprocess@zfs 未排在 bootloader 之后 → GRUB fallback 会盖过 ZBM,中止"; exit 1; }
    # shellprocess@zfspre 必须接在 bootloader 之前：它中和 grub-install。缺了它,ZFS 根上 grub-install 退 1、
    # Calamares 在 bootloader 步就中止，后面 shellprocess@zfs 的整个 ZBM 安装根本不会执行 → 出不可启动盘。
    grep -qE '^[[:space:]]*-[[:space:]]*shellprocess@zfspre[[:space:]]*$' "${CSGSET}" 2>/dev/null \
        || { echo "[99-sanitize] 致命:settings.conf 未接 shellprocess@zfspre → ZFS 根装机 grub-install 会中止，中止"; exit 1; }
    awk '/^[[:space:]]*-[[:space:]]*shellprocess@zfspre[[:space:]]*$/{p=NR} /^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$/{b=NR} END{exit !(p&&b&&p<b)}' "${CSGSET}" \
        || { echo "[99-sanitize] 致命:settings.conf 中 shellprocess@zfspre 未排在 bootloader 之前 → grub-install 会中止 ZFS 根装机，中止"; exit 1; }
    test -f "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命：缺 /etc/zfsbootmenu/config.yaml → generate-zbm 无法产单文件 EFI,中止"; exit 1; }
    grep -qE '^[[:space:]]*Enabled:[[:space:]]*true' "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命:zfsbootmenu config.yaml 未启用 EFI(EFI.Enabled:true)→ 不出单文件 EFI,中止"; exit 1; }
    # EFI stub 必须随 systemd[boot] 安装，否则 generate-zbm 装机时产不出单文件 EFI
    test -f "${SQROOT}/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
        || echo "[99-sanitize] 警告：未见 systemd EFI stub(linuxx64.efi.stub)→ 确认 sys-apps/systemd 开了 boot USE,否则装机时 generate-zbm 产不出 EFI"
    # 出锅只能有一个内核。virtual/dist-kernel 有多个 provider(gentoo-kernel-bin、vanilla-kernel、
    # gentoo-kernel-modprep…)，package.mask 漏钉任何一个，-uD @world 就会挑版本最高的那个装进来，
    # 于是多出一个超 OpenZFS 上限、没有 zfs.ko 的内核。下面按最高版查 zfs.ko 会因此致命中止，
    # 但报的是 zfs 缺模块，看不出真因，所以先在这里点名。
    NKERN=$(ls -1 "${SQROOT}/lib/modules" 2>/dev/null | wc -l)
    [ "${NKERN}" -le 1 ] \
        || { echo "[99-sanitize] 致命：装了 ${NKERN} 个内核($(ls "${SQROOT}/lib/modules" | tr '\n' ' '))→ package.mask/kernel-zfs 漏钉了某个 virtual/dist-kernel 的 provider,中止"; exit 1; }
    # 关键:zfs 用户态 + ZBM 都在，内核模块也必须真编进来了。内核超过 OpenZFS 支持上限(Linux-Maximum)时
    # zfs-kmod 会 configure 拒编、被 --keep-going 静默跳过 → 出锅 modprobe zfs 失败、根本装不了 ZFS。
    KMODVER=$(ls "${SQROOT}/lib/modules" 2>/dev/null | sort -Vr | head -n1)
    { [ -n "${KMODVER}" ] && find "${SQROOT}/lib/modules/${KMODVER}" -name 'zfs.ko*' 2>/dev/null | grep -q .; } \
        || { echo "[99-sanitize] 致命：装了 ZFS 用户态/ZBM 但内核 ${KMODVER:-?} 没有 zfs.ko(内核多半超了 OpenZFS 支持上限、zfs-kmod 被静默跳过)→ 出锅装不了 ZFS,中止(见 package.mask/kernel-zfs 的内核钉版)"; exit 1; }
    find "${SQROOT}/lib/modules/${KMODVER}" -name 'spl.ko*' 2>/dev/null | grep -q . \
        || echo "[99-sanitize] 提示：${KMODVER} 有 zfs.ko 但无独立 spl.ko(较新 OpenZFS 把 spl 并进 zfs.ko,正常)"
    # userland 与内核模块必须同版本(版本不齐 ZFS 就不能用，单查 zfs.ko 在不在会漏掉)。
    # 上游 >=2.4.1 起把 kmod 合并进 sys-fs/zfs(USE 里带 modules),一个包出用户态和模块、天然同版本，
    # 此时没有独立的 sys-fs/zfs-kmod,再拿它比对会把好锅误判成致命。故按已装 zfs 的 USE 自动分流。
    ZV=$(ls -d "${SQROOT}"/var/db/pkg/sys-fs/zfs-[0-9]* 2>/dev/null | head -1 | sed -E 's#.*/zfs-##')
    ZKV=$(ls -d "${SQROOT}"/var/db/pkg/sys-fs/zfs-kmod-[0-9]* 2>/dev/null | head -1 | sed -E 's#.*/zfs-kmod-##')
    ZUSE=" $(cat "${SQROOT}"/var/db/pkg/sys-fs/zfs-[0-9]*/USE 2>/dev/null | head -1) "
    [ -n "${ZV}" ] || { echo "[99-sanitize] 致命:squashfs 里没装 sys-fs/zfs 却有 ZBM → ZFS 不能用，中止"; exit 1; }
    case "${ZUSE}" in
        *" modules "*)
            # 合并版：模块由 zfs 自己出。zfs.ko 上面已断言存在；这里只再确认没混进旧的独立 kmod 包。
            [ -z "${ZKV}" ] \
                || { echo "[99-sanitize] 致命:zfs-${ZV} 已自带模块(USE=modules),却又装了独立 sys-fs/zfs-kmod-${ZKV} → 两份模块会打架，中止"; exit 1; }
            ZMODE="合并版 zfs-${ZV}[modules]" ;;
        *)
            # 旧拆分结构：两个包必须同版本。
            [ "${ZV}" = "${ZKV}" ] \
                || { echo "[99-sanitize] 致命:zfs userland(${ZV}) 与 zfs-kmod(${ZKV:-无}) 版本不一致 → ZFS 不能用，中止(见 package.mask/kernel-zfs 的 ZFS 钉版)"; exit 1; }
            ZMODE="拆分版 userland=kmod=${ZV}" ;;
    esac
    echo "[99-sanitize] 安全断言通过:ZFS 根装机契约已接(zfs.ko 在 ${KMODVER}、${ZMODE}、ZBM 工具/脚本/序列/config 齐备、shellprocess@zfs 在 bootloader 之后)"
else
    echo "[99-sanitize] 提示：本锅未含 generate-zbm(zfsbootmenu 未装，可能 --keep-going 跳过)→ 跳过 ZFS 根装机断言;ZFS 根安装将不可启动，非 ZFS 安装不受影响"
fi

echo "[99-sanitize] 出厂清理完成：MAKEOPTS 自适应、CPU_FLAGS 按用户机生成、镜像源设为阿里云、解除 nouveau 静态黑名单、构建调优与缓存已移除"
