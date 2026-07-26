#!/bin/bash
# 出厂安全清理（在 makesquashfs 之前由 build.sh source 执行）
#
# 构建过程中，build.sh 的 refreshconfig() 会把【构建机的】MAKEOPTS 写进系统树的
# make.conf（例如 -j32 / -j76），若不还原，最终用户（可能只有 2-4 核、4-8G 内存）
# 开机后 emerge 编译大包会内存超订甚至 OOM。此外构建若注入了二进制包缓存类调优
# （FEATURES=buildpkg、EMERGE_DEFAULT_OPTS 的 --usepkg/--buildpkg），也不应随 ISO
# 发给用户。这个 hook 在打包前把系统树还原成对普通用户安全的通用配置。
#
# 设计为幂等、与具体构建环境无关：无论谁来构建、注入了什么调优，出厂结果都一致。

MC="${WORKDIR}/squashfs/etc/portage/make.conf"

# ① MAKEOPTS 还原为安全兜底字面量 -j4。
#    切勿写 $(nproc):portage 的 make.conf 解析器【不支持】命令替换,会每次 emerge
#    报 "line N: $: bad substitution" 且 MAKEOPTS 失效。真正的按 CPU 自适应由开机的
#    gigos-cpuflags.service 写进 make.conf.d/cpuflags(字母序在 common 之后覆盖此值);
#    -j4 仅是首启动前/服务未跑时的安全兜底(小内存机也不致 OOM)。
if [ -f "${MC}/common" ]; then
    sed -i 's/^MAKEOPTS=.*/MAKEOPTS="-j4"/' "${MC}/common"
fi

# ② 移除任何构建机专用的二进制包缓存调优（若构建包装层注入过）。
#    删整文件命中的 EMERGE_DEFAULT_OPTS / FEATURES 注入片段，再逐文件擦关键字。
rm -f "${MC}"/zz-buildhost "${MC}"/zz-loadavg
if [ -d "${MC}" ]; then
    grep -rlE 'buildpkg|--usepkg|--buildpkg|load-average=' "${MC}/" 2>/dev/null \
      | while read -r f; do
            sed -i -E 's/(--usepkg|--buildpkg|--load-average=[0-9]+)//g; s/[[:space:]]+buildpkg//g' "$f"
        done
fi

# ③ CPU_FLAGS_X86 必须按【用户的】CPU 生成，不能用构建机的固定值。
#    Calamares 装机是把本 live squashfs 整盘复制到用户硬盘，所以这里的
#    make.conf 会原样成为用户系统的配置。若保留构建机的 CPU_FLAGS_X86
#    （如含 avx2），用户 CPU 若不支持，后续 emerge 编译出的包会在运行时
#    SIGILL 崩溃——这正是"第三方 live 装完不兼容/损坏系统"的典型成因。
#    出厂策略改为「带标记的安全基线 + 开机自适应服务」:cpuflags 写 x86-64-v3 基线并加
#    gigos-auto-cpuflags 标记,gigos-cpuflags.service 在 live 与装好的系统【每次启动】按
#    真机 CPU(cpuid2cpuflags,见 world)覆盖之(用户删标记即停)。比旧的"手动占位"开箱即用。
#    这里先清掉其它文件里可能残留的 CPU_FLAGS_X86,再把 cpuflags 归一成「标记+基线」
#    (与 include-squashfs 的同名文件一致,幂等)。
for f in "${MC}"/common "${MC}"/cpuflags.conf; do
    [ -f "$f" ] && sed -i '/^CPU_FLAGS_X86=/d' "$f"
done
cat > "${MC}/cpuflags" <<'CPUF'
# gigos-auto-cpuflags
# 由 gigos-cpuflags 按本机 CPU 自动生成;删除上面这行标记即停止自动覆盖,可改成自己的值。
# 下面是出厂安全基线(x86-64-v3,2013+/AVX2);开机后 gigos-cpuflags.service 按真机 CPU 覆盖。
CPU_FLAGS_X86="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 ssse3"
CPUF

# ④ 出厂 GENTOO_MIRRORS：写带标记的【基线】(中国大陆)。开机后 gigos-mirror.service 按系统语言
#    自动选就近镜像(简→大陆 / 繁→台港 / 英→全球)——我们支持简/繁/英三语,写死单一中国镜像对
#    繁体、海外用户不友好,故改成「基线 + 按语言自适应」,与 gigos-cpuflags 同套机制。
#    第一行的标记让 gigos-mirror 知道这是自动值、可覆盖;用户删掉标记即固定为自己的值。
#    注意：这与【构建时】用的源无关——构建机在香港直连官方源(见 build-and-deploy.sh / config)。
{
    echo '# gigos-auto-mirror'
    echo '# 出厂基线(中国大陆);开机后 gigos-mirror.service 按系统语言覆盖。删除本行标记即停止自动覆盖。'
    echo 'GENTOO_MIRRORS="https://mirrors.aliyun.com/gentoo/ https://mirrors.tuna.tsinghua.edu.cn/gentoo/ https://mirrors.ustc.edu.cn/gentoo/ https://mirrors.bfsu.edu.cn/gentoo/"'
} > "${MC}/mirror"

# ⑤ 解除 nvidia.conf 对 nouveau 的【静态】黑名单,让双驱动共存。
#    nvidia-drivers ebuild 自带 /etc/modprobe.d/nvidia.conf,首行 `blacklist nouveau`
#    会让整个系统(含 live)永远走不了 nouveau——这跟我们「grub 默认 nouveau、
#    选闭源项才上 nvidia」的双驱动设计直接冲突(选默认项 nouveau 也起不来)。
#    出厂注释掉这两行(ebuild 文件里明说可注释),改由 grub 内核参数动态切换:
#      - 默认/nouveau 项:无 blacklist → nouveau 加载
#      - 闭源 NVIDIA 项:cmdline modprobe.blacklist=nouveau → nvidia 接管
#    这正是 EndeavourOS/CachyOS 的做法(不静态黑名单,靠加载顺序/cmdline)。
NVCONF="${WORKDIR}/squashfs/etc/modprobe.d/nvidia.conf"
if [ -f "${NVCONF}" ]; then
    sed -i 's/^blacklist nouveau/#blacklist nouveau/; s/^blacklist nova_core/#blacklist nova_core/' "${NVCONF}"
fi

# ⑥ 兜底清空二进制包 / 源码缓存（exclude.txt 也会排除，这里双保险；
#    用 find -delete 而非 glob，空目录/不同 shell 下都可靠）。
for d in binpkgs distfiles; do
    find "${WORKDIR}/squashfs/var/cache/${d}" -mindepth 1 -delete 2>/dev/null || true
done

# ⑦ 安全断言:装机后清理 live 残留(autologin / SSH 密码登录 / 桌面调试按钮 / polkit 免密)全靠
#    calamares-settings-gig 的 shellprocess。打包前在此强校验契约确已接通——否则一旦指向 fork 失败
#    或被上游覆盖,会出「装好的系统残留 autologin / SSH 密码登录」的后门盘。任一缺失即中止,不出后门盘。
CSGSP="${WORKDIR}/squashfs/etc/calamares/modules/shellprocess.conf"
CSGSET="${WORKDIR}/squashfs/etc/calamares/settings.conf"
for pat in "sddm.conf.d/kde_settings.conf" "49-calamares-nopasswd.rules" "00-gigos-passwordlogin.conf" "gigos-nosleep.desktop" "gigos-sudo-nopasswd.desktop"; do
    grep -q "${pat}" "${CSGSP}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares 装机清理缺 ${pat} → 装好系统会残留 live 后门,中止"; exit 1; }
done
grep -qE '^[[:space:]]*-[[:space:]]*shellprocess[[:space:]]*$' "${CSGSET}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares settings.conf 未启用 shellprocess 清理步骤(清理不会跑)→ 中止"; exit 1; }
echo "[99-sanitize] 安全断言通过:装机清理契约已接(autologin / SSH 密码登录 / polkit 残留会被 calamares 删除)"

# ⑧ ZFS 根装机契约断言。仅当本锅【确实装上了 ZBM 工具】(generate-zbm 在 squashfs 内)才强校验——
#    这样 --keep-going 下若 guru 偶发使 zfsbootmenu 被跳过,非 ZFS 盘照常出;但凡装了 ZBM,就必须保证
#    装机后处理脚本在位、settings 已接 shellprocess@zfs、且 ZBM config 启用了单文件 EFI,否则 ZFS 根装出
#    不可启动盘。任一缺失即中止。
SQROOT="${WORKDIR}/squashfs"
if [ -x "${SQROOT}/usr/bin/generate-zbm" ] || [ -x "${SQROOT}/usr/sbin/generate-zbm" ]; then
    test -x "${SQROOT}/usr/local/bin/gigos-zfs-bootmenu.sh" \
        || { echo "[99-sanitize] 致命:装了 ZBM 却缺 gigos-zfs-bootmenu.sh → ZFS 根装机无引导器,中止"; exit 1; }
    grep -qE '^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$' "${CSGSET}" 2>/dev/null \
        || { echo "[99-sanitize] 致命:settings.conf 未接 shellprocess@zfs → ZFS 根装机不会装 ZBM,中止"; exit 1; }
    # shellprocess@zfs 必须接在 bootloader 之后(否则 GRUB 的 fallback EFI 会盖过 ZBM)
    awk '/^[[:space:]]*-[[:space:]]*bootloader[[:space:]]*$/{b=NR} /^[[:space:]]*-[[:space:]]*shellprocess@zfs[[:space:]]*$/{z=NR} END{exit !(b&&z&&z>b)}' "${CSGSET}" \
        || { echo "[99-sanitize] 致命:settings.conf 中 shellprocess@zfs 未排在 bootloader 之后 → GRUB fallback 会盖过 ZBM,中止"; exit 1; }
    test -f "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命:缺 /etc/zfsbootmenu/config.yaml → generate-zbm 无法产单文件 EFI,中止"; exit 1; }
    grep -qE '^[[:space:]]*Enabled:[[:space:]]*true' "${SQROOT}/etc/zfsbootmenu/config.yaml" \
        || { echo "[99-sanitize] 致命:zfsbootmenu config.yaml 未启用 EFI(EFI.Enabled:true)→ 不出单文件 EFI,中止"; exit 1; }
    # EFI stub 必须随 systemd[boot] 安装,否则 generate-zbm 装机时产不出单文件 EFI
    test -f "${SQROOT}/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
        || echo "[99-sanitize] 警告:未见 systemd EFI stub(linuxx64.efi.stub)→ 确认 sys-apps/systemd 开了 boot USE,否则装机时 generate-zbm 产不出 EFI"
    echo "[99-sanitize] 安全断言通过:ZFS 根装机契约已接(ZBM 工具/脚本/序列/config 齐备,shellprocess@zfs 在 bootloader 之后)"
else
    echo "[99-sanitize] 提示:本锅未含 generate-zbm(zfsbootmenu 未装,可能 --keep-going 跳过)→ 跳过 ZFS 根装机断言;ZFS 根安装将不可启动,非 ZFS 安装不受影响"
fi

echo "[99-sanitize] 出厂清理完成：MAKEOPTS 自适应、CPU_FLAGS 按用户机生成、镜像源设为阿里云、解除 nouveau 静态黑名单、构建调优与缓存已移除"
