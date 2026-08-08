#!/bin/bash
# 出厂安全清理，由 build.sh 在 makesquashfs 之前 source 执行。
# 构建期写进系统树的构建机专属配置会原样发给用户：MAKEOPTS 的高并发会让小内存机编译时 OOM，
# binpkg 缓存类调优也不该随 ISO 发出。本 hook 在打包前把系统树还原成通用配置，幂等且与构建环境无关。

MC="${WORKDIR}/squashfs/etc/portage/make.conf"

# 1. MAKEOPTS 还原为字面量 -j4。不能写 $(nproc)：portage 的 make.conf 解析器不支持命令替换，
#    会报 bad substitution 且 MAKEOPTS 失效。按 CPU 自适应由 gigos-cpuflags.service 写进
#    make.conf.d/cpuflags，字母序在 common 之后覆盖此值，-j4 只是该服务执行前的兜底。
if [ -f "${MC}/common" ]; then
    sed -i 's/^MAKEOPTS=.*/MAKEOPTS="-j4"/' "${MC}/common"
fi

# 2. 移除构建包装层可能注入的二进制包缓存调优：先删整个注入文件，再逐文件擦除关键字。
rm -f "${MC}"/zz-buildhost
if [ -d "${MC}" ]; then
    grep -rlE 'buildpkg|--usepkg|--buildpkg|load-average=' "${MC}/" 2>/dev/null \
      | while read -r f; do
            sed -i -E 's/(--usepkg|--buildpkg|--load-average=[0-9]+)//g; s/[[:space:]]+buildpkg//g' "$f"
        done
fi

# 2.5 清除 --autounmask-continue 在构建期写下的 zz-autounmask。CONFIG_PROTECT="-*" 下这些文件
#     直接落进系统树，属构建期滚动树漂移的产物，不应随 ISO 发给用户。
PRT="${WORKDIR}/squashfs/etc/portage"
rm -f "${PRT}/package.use/zz-autounmask" "${PRT}/package.accept_keywords/zz-autounmask" \
      "${PRT}/package.mask/zz-autounmask" "${PRT}/package.license/zz-autounmask" 2>/dev/null || true

# 3. CPU_FLAGS_X86 不能留构建机的固定值。Calamares 把 live squashfs 整盘复制到用户硬盘，
#    此处的 make.conf 会原样成为用户系统的配置，留下用户 CPU 不支持的标志位会让后续 emerge
#    编译出的包在运行时 SIGILL。出厂写 x86-64-v3 基线并加 gigos-auto-cpuflags 标记，
#    gigos-cpuflags.service 每次启动按真机 CPU 覆盖，用户删除标记即停止覆盖。
for f in "${MC}"/common; do
    [ -f "$f" ] && sed -i '/^CPU_FLAGS_X86=/d' "$f"
done
cat > "${MC}/cpuflags" <<'CPUF'
# gigos-auto-cpuflags
# 由 gigos-cpuflags 按本机 CPU 自动生成；删除上面这行标记即停止自动覆盖，可改成自己的值。
# 下面是出厂安全基线(x86-64-v3,2013+/AVX2);开机后 gigos-cpuflags.service 按真机 CPU 覆盖。
CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 ssse3"
CPUF

# 4. GENTOO_MIRRORS 写带标记的海外基线，开机后由 gigos-mirror.service 按出口 IP 国家码改为就近镜像，
#    无法取得国家码时改按系统语言，机制与 gigos-cpuflags 相同。用户删除标记即固定当前值。
{
    echo '# gigos-auto-mirror'
    echo '# 出厂基线是海外源，开机后 gigos-mirror.service 按出口 IP 或系统语言覆盖。删除本行标记即停止自动覆盖。'
    echo 'GENTOO_MIRRORS="https://distfiles.gentoo.org/ https://gentoo.osuosl.org/ https://ftp.fau.de/gentoo/"'
} > "${MC}/mirror"

# gigos-mirror 运行期生成的 repos.conf 覆盖文件按开机时判定的地区写入，
# 打包进 ISO 会把构建机所在地区的源发给所有用户，故出厂前删除。
rm -f "${WORKDIR}/squashfs/etc/portage/repos.conf/zz-gigos-mirror.conf" \
      "${WORKDIR}/squashfs/etc/portage/binrepos.conf/gentoo-zh.conf"

# 解除 nvidia.conf 静态黑名单这件事在 hooks/04nvidia-dual-driver.sh，它先于本文件执行。
# 原先此处也有一份，但 04 已把行首改成 `#blacklist`，这里的 `^blacklist` 再也匹配不到，是死代码。

# 6. 清空二进制包与源码缓存。exclude.txt 已排除这两个目录，此处是第二道保险；
#    用 find -delete 而非 glob，空目录与不同 shell 下都可靠。
for d in binpkgs distfiles; do
    _cachedir="${WORKDIR}/squashfs/var/cache/${d}"
    # 构建机把宿主的持久缓存 bind 挂载到这两个目录，挂载状态下删除会穿过 bind 清空宿主缓存，
    # 下一次只能从零编译。squashfs 已由 exclude.txt 排除，跳过不影响出厂结果。
    if mountpoint -q "${_cachedir}" 2>/dev/null; then
        echo "[99-sanitize] ${d} 是 bind 挂载的宿主缓存，跳过清理(exclude.txt 已排除，不会进 ISO)"
        continue
    fi
    find "${_cachedir}" -mindepth 1 -delete 2>/dev/null || true
done
unset _cachedir

# 7. 装机后清理 live 残留（autologin、SSH 密码登录、桌面调试按钮、polkit 免密）全靠
#    calamares-settings-gig 的 shellprocess。打包前校验该契约已接通，否则指向 fork 失败或被上游覆盖时，
#    装好的系统仍会残留 autologin 与 SSH 密码登录。任一缺失即中止。
CSGSP="${WORKDIR}/squashfs/etc/calamares/modules/shellprocess.conf"
CSGSET="${WORKDIR}/squashfs/etc/calamares/settings.conf"
for pat in "sddm.conf.d/kde_settings.conf" "49-calamares-nopasswd.rules" "00-gigos-passwordlogin.conf" "gigos-nosleep.desktop" "gigos-sudo-nopasswd.desktop"; do
    grep -q "${pat}" "${CSGSP}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares 装机清理缺 ${pat} → 装好的系统会残留 live 后门，中止"; exit 1; }
done
grep -qE '^[[:space:]]*-[[:space:]]*shellprocess[[:space:]]*$' "${CSGSET}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares settings.conf 未启用 shellprocess 清理步骤(清理不会执行)→ 中止"; exit 1; }
echo "[99-sanitize] 安全断言通过：装机清理契约已接(autologin / SSH 密码登录 / polkit 残留会被 calamares 删除)"

# 7.5 settings.conf 排入的每个模块在 calamares 中都必须存在。calamares 大版本会增删模块，
#      而 settings.conf 由本项目的 fork 维护：排入新版没有的模块时构建期一切正常，装机执行到该步才失败。
#      故出厂前静态比对 settings.conf 的 sequence 与已安装的 calamares 模块目录，不匹配即中止。
CALMODDIR=""
for d in "${WORKDIR}/squashfs"/usr/lib64/calamares/modules "${WORKDIR}/squashfs"/usr/lib/calamares/modules; do
    [ -d "${d}" ] && { CALMODDIR="${d}"; break; }
done
if [ -f "${CSGSET}" ] && [ -n "${CALMODDIR}" ]; then
    MISSMOD=""
    # 只取 sequence 段中形如 `- 模块名` 的整行，排除 instances 段带冒号的 `- id: xxx`；
    # shellprocess@nvidia 这类实例回落到基础模块名。
    for m in $(sed -n '/^sequence:/,/^[a-z]/p' "${CSGSET}" 2>/dev/null \
               | grep -oE '^[[:space:]]*-[[:space:]]*[a-z0-9@_.-]+[[:space:]]*$' \
               | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*$//; s/@.*//' | sort -u); do
        [ -d "${CALMODDIR}/${m}" ] || ls "${CALMODDIR}/${m}".* >/dev/null 2>&1 || MISSMOD="${MISSMOD} ${m}"
    done
    [ -z "${MISSMOD}" ] \
        || { echo "[99-sanitize] 致命:settings.conf 排入了 calamares 中不存在的模块：${MISSMOD} → 装机执行到该步会失败，中止(calamares 升过大版本？对照 ${CALMODDIR##*/squashfs})"; exit 1; }
    echo "[99-sanitize] 安全断言通过:settings.conf 的模块在本次 calamares 中全部存在"
else
    echo "[99-sanitize] 提示：未找到 calamares 模块目录或 settings.conf,跳过模块比对"
fi

# 8. ZFS 根装机契约断言。只在本次确实安装了 generate-zbm 时校验，这样 --keep-going 跳过
#    zfsbootmenu 时非 ZFS 盘照常出。装了 ZBM 就必须保证装机后处理脚本在位、settings 已接
#    shellprocess@zfs、config 启用单文件 EFI，任一缺失即中止，否则 ZFS 根会装出不可启动的盘。
SQROOT="${WORKDIR}/squashfs"
if [ -x "${SQROOT}/usr/bin/generate-zbm" ] || [ -x "${SQROOT}/usr/sbin/generate-zbm" ]; then
    test -x "${SQROOT}/usr/local/bin/gigos-zfs-bootmenu.sh" \
        || { echo "[99-sanitize] 致命：装了 ZBM 却缺 gigos-zfs-bootmenu.sh → ZFS 根装机无引导器，中止"; exit 1; }
    grep -qE '^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$' "${CSGSET}" 2>/dev/null \
        || { echo "[99-sanitize] 致命:settings.conf 未接 shellprocess@zfs → ZFS 根装机不会装 ZBM,中止"; exit 1; }
    # shellprocess@zfs 必须接在 bootloader 之后，否则 GRUB 的 fallback EFI 会覆盖 ZBM。
    awk '/^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$/{b=NR} /^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$/{z=NR} END{exit !(b&&z&&z>b)}' "${CSGSET}" \
        || { echo "[99-sanitize] 致命:settings.conf 中 shellprocess@zfs 未排在 bootloader 之后 → GRUB fallback 会盖过 ZBM,中止"; exit 1; }
    # shellprocess@zfspre 必须接在 bootloader 之前，它负责中和 grub-install。缺少它时 ZFS 根上
    # grub-install 返回 1，Calamares 在 bootloader 步中止，后续 shellprocess@zfs 的 ZBM 安装根本轮不到执行。
    grep -qE '^[[:space:]]*-[[:space:]]*shellprocess@zfspre[[:space:]]*$' "${CSGSET}" 2>/dev/null \
        || { echo "[99-sanitize] 致命:settings.conf 未接 shellprocess@zfspre → ZFS 根装机 grub-install 会中止，中止"; exit 1; }
    awk '/^[[:space:]]*-[[:space:]]*shellprocess@zfspre[[:space:]]*$/{p=NR} /^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$/{b=NR} END{exit !(p&&b&&p<b)}' "${CSGSET}" \
        || { echo "[99-sanitize] 致命:settings.conf 中 shellprocess@zfspre 未排在 bootloader 之前 → grub-install 会中止 ZFS 根装机，中止"; exit 1; }
    test -f "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命：缺 /etc/zfsbootmenu/config.yaml → generate-zbm 无法产单文件 EFI,中止"; exit 1; }
    grep -qE '^[[:space:]]*Enabled:[[:space:]]*true' "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命:zfsbootmenu config.yaml 未启用 EFI(EFI.Enabled:true)→ 不出单文件 EFI,中止"; exit 1; }
    # EFI stub 必须随 systemd[boot] 安装，否则 generate-zbm 装机时产不出单文件 EFI。
    test -f "${SQROOT}/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
        || echo "[99-sanitize] 警告：未见 systemd EFI stub(linuxx64.efi.stub)→ 确认 sys-apps/systemd 开了 boot USE,否则装机时 generate-zbm 产不出 EFI"
    # 出厂只能有一个内核。virtual/dist-kernel 有多个 provider，package.mask 漏钉任何一个，
    # -uD @world 就会装进版本最高的那个，多出一个超 OpenZFS 上限、没有 zfs.ko 的内核。
    # 下面按最高版查 zfs.ko 虽然也会中止，但报的是 zfs 缺模块、看不出真因，故先在此处点名。
    NKERN=$(ls -1 "${SQROOT}/lib/modules" 2>/dev/null | wc -l)
    [ "${NKERN}" -le 1 ] \
        || { echo "[99-sanitize] 致命：装了 ${NKERN} 个内核($(ls "${SQROOT}/lib/modules" | tr '\n' ' '))→ package.mask/kernel-zfs 漏钉了某个 virtual/dist-kernel 的 provider,中止"; exit 1; }
    # zfs 用户态与 ZBM 都在时，内核模块也必须已编入。内核超过 OpenZFS 支持上限（Linux-Maximum）时
    # zfs-kmod 在 configure 阶段拒绝编译并被 --keep-going 静默跳过，出厂后 modprobe zfs 失败、无法安装 ZFS。
    KMODVER=$(ls "${SQROOT}/lib/modules" 2>/dev/null | sort -Vr | head -n1)
    if ! { [ -n "${KMODVER}" ] && find "${SQROOT}/lib/modules/${KMODVER}" -name 'zfs.ko*' 2>/dev/null | grep -q .; }; then
        WANTKV=$(grep -hoE '/lib/modules/[^/]+/extra/zfs\.ko' \
                 "${SQROOT}"/var/db/pkg/sys-fs/zfs-[0-9]*/CONTENTS 2>/dev/null | head -n1 | cut -d/ -f4)
        if [ -n "${WANTKV}" ] && [ "${WANTKV}" != "${KMODVER}" ]; then
            echo "[99-sanitize] 致命：zfs 的模块编给内核 ${WANTKV}，本机内核是 ${KMODVER} → 装到了别处编的 binpkg,出厂装不了 ZFS,中止(build.sh 的 --usepkg-exclude 要盖住 sys-fs/zfs)"
        else
            echo "[99-sanitize] 致命：装了 ZFS 用户态/ZBM 但内核 ${KMODVER:-?} 没有 zfs.ko(内核多半超了 OpenZFS 支持上限、模块被静默跳过)→ 出厂装不了 ZFS,中止(见 package.mask/kernel-zfs 的内核钉版)"
        fi
        exit 1
    fi
# nvidia 的内核模块同样只能本机编。zfs 那条断言之外再查一次：出 .ko 的包只有 zfs 与
# nvidia-drivers，后者装错 KV 时没有别的闸门拦得住，用户选闭源启动项会直接黑屏。
NVKO=$(grep -hoE 'lib/modules/[^/]+/[^ ]*nvidia\.ko' "${SQROOT}"/var/db/pkg/x11-drivers/nvidia-drivers-*/CONTENTS 2>/dev/null | head -n1)
if [ -n "${NVKO}" ]; then
    NVKV=$(printf '%s' "${NVKO}" | cut -d/ -f3)
    [ "${NVKV}" = "${KMODVER}" ] \
        || { echo "[99-sanitize] 致命：nvidia 的模块编给内核 ${NVKV}，本机内核是 ${KMODVER} → 装到了别处编的 binpkg,闭源启动项会黑屏，中止(build.sh 的 --usepkg-exclude 要盖住 x11-drivers/nvidia-drivers)"; exit 1; }
fi

    find "${SQROOT}/lib/modules/${KMODVER}" -name 'spl.ko*' 2>/dev/null | grep -q . \
        || echo "[99-sanitize] 提示：${KMODVER} 有 zfs.ko 但无独立 spl.ko(较新 OpenZFS 把 spl 并进 zfs.ko,正常)"
    # 用户态与内核模块必须同版本，只查 zfs.ko 是否存在会漏掉版本不一致的情况。
    # 上游 >=2.4.1 起把 kmod 并入 sys-fs/zfs（USE 带 modules），一个包同时提供用户态与模块、天然同版本，
    # 此时没有独立的 sys-fs/zfs-kmod，再拿它比对会把正常构建误判为致命。故按已安装 zfs 的 USE 分流。
    ZV=$(ls -d "${SQROOT}"/var/db/pkg/sys-fs/zfs-[0-9]* 2>/dev/null | head -1 | sed -E 's#.*/zfs-##')
    ZKV=$(ls -d "${SQROOT}"/var/db/pkg/sys-fs/zfs-kmod-[0-9]* 2>/dev/null | head -1 | sed -E 's#.*/zfs-kmod-##')
    ZUSE=" $(cat "${SQROOT}"/var/db/pkg/sys-fs/zfs-[0-9]*/USE 2>/dev/null | head -1) "
    [ -n "${ZV}" ] || { echo "[99-sanitize] 致命:squashfs 里没装 sys-fs/zfs 却有 ZBM → ZFS 不能用，中止"; exit 1; }
    case "${ZUSE}" in
        *" modules "*)
            # 合并版由 zfs 自身提供模块，zfs.ko 已在上面断言，此处只确认没有混入旧的独立 kmod 包。
            [ -z "${ZKV}" ] \
                || { echo "[99-sanitize] 致命:zfs-${ZV} 已自带模块(USE=modules),却又装了独立 sys-fs/zfs-kmod-${ZKV} → 两份模块冲突，中止"; exit 1; }
            ZMODE="合并版 zfs-${ZV}[modules]" ;;
        *)
            # 旧拆分结构的两个包必须同版本。
            [ "${ZV}" = "${ZKV}" ] \
                || { echo "[99-sanitize] 致命:zfs userland(${ZV}) 与 zfs-kmod(${ZKV:-无}) 版本不一致 → ZFS 不能用，中止(见 package.mask/kernel-zfs 的 ZFS 钉版)"; exit 1; }
            ZMODE="拆分版 userland=kmod=${ZV}" ;;
    esac
    echo "[99-sanitize] 安全断言通过:ZFS 根装机契约已接(zfs.ko 在 ${KMODVER}、${ZMODE}、ZBM 工具/脚本/序列/config 齐备、shellprocess@zfs 在 bootloader 之后)"
else
    echo "[99-sanitize] 提示：本次未含 generate-zbm(zfsbootmenu 未装，可能 --keep-going 跳过)→ 跳过 ZFS 根装机断言;ZFS 根安装将不可启动，非 ZFS 安装不受影响"
fi

echo "[99-sanitize] 出厂清理完成：MAKEOPTS 自适应、CPU_FLAGS 按用户机生成、镜像源设为海外基线(开机按出口 IP 或语言改写)、解除 nouveau 静态黑名单、构建调优与缓存已移除"
