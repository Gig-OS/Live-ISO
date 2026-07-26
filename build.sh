#!/bin/bash

WORKDIR="$(dirname "$(realpath "$0")")"

source "${WORKDIR}"/config

function cleanmount () {
    umount -l "${WORKDIR}/squashfs/var/tmp/portage" || true
    umount -l "${WORKDIR}/squashfs/mnt/gen-iso" || true
    umount -l "${WORKDIR}/squashfs/var/cache/binpkgs" 2>/dev/null || true
    umount -l "${WORKDIR}/squashfs/var/cache/distfiles" 2>/dev/null || true
    exit
}

# wget 统一加超时/重试/续传，-nv 保留错误进日志（-q 会吞掉网络错误）
WGET="wget -nv --timeout=30 --tries=3 -c"

function fetchstage3 () {
    ${WGET} "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" -O "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" || exit 1
    STAGE3PATH="$(sed -n '6p' "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | cut -f 1 -d ' ')"
    echo "STAGE3PATH:" "${STAGE3PATH}"
    # 守卫:latest txt 下载/解析失败会得到空串,空串会让 wget 去抓目录索引写坏文件
    [ -n "${STAGE3PATH}" ] || { echo "解析 stage3 路径失败"; exit 1; }
    STAGE3="$(basename "${STAGE3PATH}")"

    if ( ! grep 'stage3downloadok' "${WORKDIR}/stat" );then
        rm -rf "squashfs/${STAGE3}"
        ${WGET} "${DIST}/${STAGE3PATH}" -O "squashfs/${STAGE3}" || exit 1
        # 校验 sha256:官方每个 stage3 同目录有 .sha256(PGP 包裹),取其中
        # 64 位十六进制那行喂给 sha256sum -c,不过即终止,挡掉坏/被篡改的 stage3
        ${WGET} "${DIST}/${STAGE3PATH}.sha256" -O "squashfs/${STAGE3}.sha256" || exit 1
        ( cd squashfs && grep -E "^[0-9a-f]{64}.*$(basename "${STAGE3}")" "${STAGE3}.sha256" | sha256sum -c - ) \
            || { echo "stage3 sha256 校验失败"; exit 1; }
        rm -f "squashfs/${STAGE3}.sha256"
        echo 'stage3downloadok' >> "${WORKDIR}/stat"
    fi
}

function unpackstage3 () {
    # unpack stage3
    pushd "${WORKDIR}/squashfs" || exit 1
    if ( ! grep 'unpackok' "${WORKDIR}/stat" );then
        tar xpf "${STAGE3}" --xattrs-include='*.*' --numeric-owner \
            && echo 'unpackok' >> "${WORKDIR}/stat" \
	        && rm "${STAGE3}" || exit 1
    fi
popd || exit 1
}

function buildarchscript () {
    # check arch-chroot tools
    if [ ! -f "${WORKDIR}/arch-scripts/arch-chroot.in" ];then
        git submodule update --init --recursive || exit 1
    fi
    if [ ! -x "${WORKDIR}/arch-scripts/arch-chroot" ];then
        pushd "${WORKDIR}/arch-scripts" || exit 1
        make || exit 1
        popd || exit 1
    fi
}

function crun () {
	"${WORKDIR}"/arch-scripts/arch-chroot "${WORKDIR}/squashfs" bash -c "$*"
}

# 瞬时失败（网络/DNS 抽风等）自动重试，免得一次抖动毁掉整锅。次数/间隔见 config。
# 配 binpkg 缓存，重试只重做失败的包，已成功的走缓存跳过，代价小。
retry () {
    local n=1
    until "$@";do
        [ "${n}" -ge "${RETRY_MAX}" ] && return 1
        echo "[gigos] 第 ${n}/${RETRY_MAX} 次失败，${RETRY_DELAY}s 后重试：$*"
        n=$((n+1)); sleep "${RETRY_DELAY}"
    done
}

# 从 chroot 树的 md5-cache 读某包的最新 amd64-STABLE 版本(精确 token 匹配,区分 amd64 与 ~amd64)。
# 用 md5-cache 而非 `ACCEPT_KEYWORDS=amd64 emerge`:后者是增量变量,会跟 chroot make.conf 的 "~amd64 *"
# 累加而非替换、压不住测试版(实机踩过:算出的是 gcc-16 快照 / 内核 7.1.3 / zfs-2.4.3 测试版)。
# md5-cache 随 gentoo git 树自带,离线可读、与 ACCEPT_KEYWORDS 无关。
newest_stable () {
    local cat="${1%/*}" pn="${1#*/}"
    local mc="${WORKDIR}/squashfs/var/db/repos/gentoo/metadata/md5-cache"
    local f
    for f in "${mc}/${cat}/${pn}"-[0-9]*; do
        [ -f "${f}" ] || continue
        awk -F= '/^KEYWORDS=/{n=split($2,a," "); for(i=1;i<=n;i++) if(a[i]=="amd64") ok=1} END{exit !ok}' "${f}" || continue
        basename "${f}" | sed "s/^${pn}-//"
    done | sort -V | tail -1
}

function syncrepo () {
# try three times to sync
if [ -d "${WORKDIR}/squashfs/var/db/repos/gentoo" ];then
    for n in {1..3};do
	if (crun which git);then
            if (crun emerge --sync);then
                break;
            fi
        else
            pushd "${WORKDIR}/squashfs/var/db/repos/gentoo" || exit 1
            if (git pull);then
                popd || exit 1
                break;
            else
                popd || exit 1
            fi
        fi
        if [ "${n}" == "3" ];then
            exit 1
        fi
    done
else
    for n in {1..3};do
        if (git clone --depth=1 "${GITMIRROR}" "${WORKDIR}/squashfs/var/db/repos/gentoo");then
            break;
        fi
        if [ "${n}" == "3" ];then
            exit 1
        fi
    done
fi
}

function refreshconfig() {
    # refresh MAKEOPTS
    sed -i "s/MAKEOPTS=\".*\"/MAKEOPTS=\""${MAKEOPTS}"\"/g" "${WORKDIR}/squashfs/etc/portage/make.conf/common"

    # 写 distfiles 源。直接用 config 的 ${GENTOO_MIRRORS},不再硬拼 /gentoo:官方源根目录没有
    # /gentoo 前缀(会 404),CN 镜像才有,各自在 config 里定。
    echo "GENTOO_MIRRORS=\"${GENTOO_MIRRORS}\"" > "${WORKDIR}/squashfs/etc/portage/make.conf/mirror"
}

function mounttmpfs () {
    if [[ -n "${TMPFS}" ]];then
        # init notmpfs dir
        crun mkdir -p /var/tmp/{notmpfs,portage}
        crun chown portage:portage /var/tmp/{notmpfs,portage}
        crun chmod 775 /var/tmp/{notmpfs,portage}
        # mount tmpfs
        if ( ! findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -t tmpfs -o size="${TMPFS}",uid=portage,gid=portage,mode=775 tmpfs /var/tmp/portage
        elif ( findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -o remount,size="${TMPFS}" /var/tmp/portage
        fi
    fi
    # 持久缓存 bind 进 chroot:设了 BINPKG_CACHE / DISTFILES_CACHE(指向宿主 SSD)就 bind,
    # 跨次构建复用 binpkg / distfiles 加速;手动构建不设则照常无缓存。
    if [ -n "${BINPKG_CACHE}" ];then
        mkdir -p "${WORKDIR}/squashfs/var/cache/binpkgs"
        findmnt "${WORKDIR}/squashfs/var/cache/binpkgs" >/dev/null || mount --bind "${BINPKG_CACHE}" "${WORKDIR}/squashfs/var/cache/binpkgs"
    fi
    if [ -n "${DISTFILES_CACHE}" ];then
        mkdir -p "${WORKDIR}/squashfs/var/cache/distfiles"
        findmnt "${WORKDIR}/squashfs/var/cache/distfiles" >/dev/null || mount --bind "${DISTFILES_CACHE}" "${WORKDIR}/squashfs/var/cache/distfiles"
    fi
}

function makesquashfs (){
    mkdir -p "${WORKDIR}/iso/LiveOS"
    rm -f "${WORKDIR}/iso/LiveOS/squashfs.img"
    # squashfs 用 zstd 而非 xz:zstd 解压快得多,live 从 U 盘边读边解压更流畅;
    # -Xcompression-level 19 压缩率仍接近 xz。(squashfs-tools 已开 zstd USE)。块大小 1M。
    mksquashfs "${WORKDIR}/squashfs/" "${WORKDIR}/iso/LiveOS/squashfs.img" \
    -wildcards -ef exclude.txt -b 1024K -comp zstd -Xcompression-level 19 -progress -processors "${CORES}" || exit 1
}

function buildbootfiles () {
    # make initramfs with live support
    KVER="$(ls "${WORKDIR}/squashfs/lib/modules" | sort -Vr | head -n1)"
    # --xz:与官方 livegui 一致的 initramfs 压缩,体积更小
    #
    # nvidia 闭源驱动不进 initramfs(不走 early KMS):闭源 grub 项传 gigos.gpu=nvidia,
    # 开机后由 gigos-nvidia-load.service 常规 modprobe nvidia 四件套 + 建设备节点(此时 udev 已就绪、
    # /dev/nvidia* 正常创建)。这是 Arch/Gentoo wiki 推荐的常规做法,比 early KMS 简单可靠、
    # 不踩 initramfs 漏建节点(nvidia-smi 连不上、KWin 退软渲)那一串坑。
    # --omit network-manager:本地介质启动的 live 不需要 initrd 内联网络;若把 NM 模块打进
    # initramfs,其 NetworkManager-initrd.service(BusName=org.freedesktop.NetworkManager)会在
    # initrd 阶段被加载并随 switch-root 带进真根,与真根的 NetworkManager.service 撞同一 BusName,
    # 导致 systemd 拒载 NM.service → 开机网络不自起。从源头不放进 initramfs 即可避免。
    crun dracut --no-hostonly -f --kver "${KVER}" --xz --add dmsquash-live --add dmsquash-live-autooverlay --add crypt --omit network-manager || exit 1

    # copy the kernel to iso workdir
    mkdir -p "${WORKDIR}/iso/boot"
    cp -v "${WORKDIR}/squashfs/boot/kernel-${KVER}" "${WORKDIR}/iso/boot/kernel" || exit 1
    cp -v "${WORKDIR}/squashfs/boot/initramfs-${KVER}.img" "${WORKDIR}/iso/boot/initrd" || exit 1
}

function buildiso () {
    # bind iso dir to rootfs to make iso
    if ( ! findmnt "${WORKDIR}/squashfs/mnt/gen-iso" );then
        mkdir -p "${WORKDIR}/squashfs/mnt/gen-iso"
        mount --bind "${WORKDIR}" "${WORKDIR}/squashfs/mnt/gen-iso"
    fi
    crun grub-mkrescue -o /mnt/gen-iso/gig-os-"$(date +%Y%m%d)".iso /mnt/gen-iso/iso -- -as mkisofs -V 'Gig-OS' || exit 1
}

# ctrl+c anytime to stop
trap cleanmount INT
trap cleanmount EXIT

# must run as root
if (( EUID != 0 ));then
    echo 'This script must be run with root privileges'
    exit 1
fi

# 防并发:任何一次 build 互斥(手动跑、autobuild 都管;锁在 build.sh 而非 wrapper,
# 这样直接跑 build.sh 也不会跟 autobuild 撞同一份 squashfs/缓存)
exec 9>/run/gigos-build.lock
flock -n 9 || { echo '已有构建在跑(/run/gigos-build.lock 被占),退出'; exit 1; }

# Download the stage3
mkdir -p "${WORKDIR}/squashfs"

fetchstage3

unpackstage3

buildarchscript

# 注入 include-squashfs。package.use 也一起注入(早注入无害):上游曾排除它、指望第二次
# rsync 补,但增量算法会漏 → chroot 里 package.use 空 → calamares 依赖的 boost/libpwquality
# [python] USE 没配、装不上。make.conf/use 仍排除(等系统就绪再给)。
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" --exclude etc/portage/make.conf/use || exit 1

refreshconfig
mounttmpfs

# [gigos] 生成 locale。fork 出的是中文 ISO(locale.conf=zh_CN.UTF-8),却一直没带 locale.gen,该 locale
# 从没生成过。构建期 btrfs-progs 的 man 走 sphinx(python),按 LANG 调 setlocale('') 读到未生成的
# zh_CN.UTF-8 → locale.Error、man 编译失败(实机卡在 btrfs-progs 并连累依赖它的 calamares-settings-gig)。
# 直接用 localedef 生成需要的两个真 locale(不走 locale-gen:它会强行把内建的 C.UTF-8 也算进去,而纯
# stage3 里 C.UTF-8 编不出 → 「not all compiled」中止整锅;C.UTF-8 是内建 locale,本就无需生成)。
# localedef 遇字符集告警也可能返回非零,故不看退出码,改断言 zh_CN 真生成出来了(它才是构建 LANG 依赖的)。
crun localedef -i en_US -f UTF-8 en_US.UTF-8 || true
crun localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 || true
crun locale -a 2>/dev/null | grep -qi '^zh_CN' || { echo "[gigos] 致命:zh_CN.UTF-8 locale 没能生成,man/sphinx 会编挂,中止"; exit 1; }
echo "[gigos] locale 就绪:$(crun locale -a 2>/dev/null | grep -iE '^en_US|^zh_CN' | tr '\n' ' ')"

# DNS
cp --dereference /etc/resolv.conf "${WORKDIR}/squashfs"/etc/

syncrepo

# [gigos] 动态钉最新 amd64-stable 工具链(gcc)+ 内核 + zfs —— 必须放在【任何 emerge 之前】:下面 portage/git
# 升级会用 -D 拖来 gcc,晚了 gcc-16 快照就先装进来了。全局 ACCEPT_KEYWORDS="~amd64 *" 默认挑最新测试版
# (实机踩过:内核 7.1.3 超 OpenZFS 上限、zfs-2.4.3 拖 RC 模块、gcc-16 快照把 btrfs-progs 编挂)。从刚同步好的
# 树的 md5-cache 精确读各自最新 amd64-stable 版本(newest_stable,不靠 ACCEPT_KEYWORDS——它是增量变量、会跟
# make.conf 的 ~amd64 * 累加压不住),再 mask 掉其上的测试版,portage 就停在 stable。两条兼容(内核 ≤ zfs-kmod
# 上限、zfs=zfs-kmod 同版本)由 99-sanitize 出锅前硬断言兜底。改钉版策略就改这一段。
GSTAB=$(newest_stable sys-devel/gcc)
KSTAB=$(newest_stable sys-kernel/gentoo-kernel-bin)
# ZSTAB 取【zfs-kmod】的最新 stable(不是 sys-fs/zfs 用户态):内核模块才是约束——userland 可能比 kmod 先稳定
# (实机遇到 zfs-2.4.3 已 stable 但 zfs-kmod-2.4.3 还不存在,kmod 最新 stable 只到 2.3.6)。以 kmod 为准、
# userland 跟到同版本(zfs-${ZSTAB} 也是 stable,且 Gentoo 用 ~zfs-kmod-${PV} 锁两者匹配)。
ZSTAB=$(newest_stable sys-fs/zfs-kmod)
[ -n "${KSTAB}" ] && [ -n "${ZSTAB}" ] && [ -n "${GSTAB}" ] || { echo "[gigos] 致命:算不出 amd64-stable 内核/zfs/gcc 版本(md5-cache 读不到?树没同步好?),中止"; exit 1; }
ZKMAX=$(grep -oE 'MODULES_KERNEL_MAX=[0-9.]+' "${WORKDIR}/squashfs/var/db/repos/gentoo/sys-fs/zfs-kmod/zfs-kmod-${ZSTAB}.ebuild" 2>/dev/null | head -1 | cut -d= -f2)
KMM=$(echo "${KSTAB}" | cut -d. -f1-2)
echo "[gigos] 动态 stable 钉版:gcc ${GSTAB}、内核 ${KSTAB}、zfs/zfs-kmod ${ZSTAB}(zfs-kmod 内核上限 ${ZKMAX:-未知})"
if [ -n "${ZKMAX}" ] && [ "$(printf '%s\n%s\n' "${ZKMAX}" "${KMM}" | sort -V | tail -1)" = "${KMM}" ] && [ "${KMM}" != "${ZKMAX}" ];then
    echo "[gigos] 警告:stable 内核 ${KMM} 超过 stable zfs-kmod 上限 ${ZKMAX},zfs-kmod 可能编不过(靠 99-sanitize 断言兜底)"
fi
mkdir -p "${WORKDIR}/squashfs/etc/portage/package.mask"
cat > "${WORKDIR}/squashfs/etc/portage/package.mask/kernel-zfs" <<MASKEOF
# 本文件由 build.sh 每锅动态生成:钉最新 amd64-stable gcc + 内核 + zfs,免手工维护(改法见 build.sh 生成它那段)。
# 本锅算得:gcc ${GSTAB}、内核 ${KSTAB}、zfs/zfs-kmod ${ZSTAB}。mask 掉算出的 stable 版之上的测试版,portage 停在 stable。
# vanilla-kernel 必须一起 mask:sys-fs/zfs[dist-kernel] 依赖【无版本】的 virtual/dist-kernel,-uD @world 会挑
# 版本最高的 provider 来满足它。gentoo-kernel-bin 钉在 ${KSTAB} 了,但 vanilla-kernel 没钉 → 实机上被拖来
# vanilla-kernel-7.1.3(装出第二个内核 /lib/modules/7.1.3-dist),它超 OpenZFS 上限、没 zfs.ko,被 99-sanitize
# 逮住中止。把 vanilla-kernel 也钉到 ${KSTAB},virtual/dist-kernel 就只能落到 gentoo-kernel-bin-${KSTAB}(world 里已有)。
>sys-devel/gcc-${GSTAB}
>sys-kernel/gentoo-kernel-bin-${KSTAB}
>sys-kernel/gentoo-kernel-${KSTAB}
>sys-kernel/gentoo-sources-${KSTAB}
>sys-kernel/vanilla-kernel-${KSTAB}
>sys-fs/zfs-${ZSTAB}
>sys-fs/zfs-kmod-${ZSTAB}
MASKEOF

# 先升级 portage。FEATURES="-merge-sync":portage 3.0.79 自升级时 _post_merge_sync 引用新版
# 才有的 _SyncfsProcess 模块,运行中的旧 portage 没有 → ModuleNotFoundError、安装失败。
# merge-sync 只为防断电丢数据,对 tmpfs 全内存构建无意义,关掉零损失。
retry crun FEATURES="-merge-sync" emerge -vu1q --jobs "${CORES}" portage
# we need git to sync overlay
if ( ! crun which git);then
    crun emerge -vuDq --jobs "${CORES}" dev-vcs/git || exit 1
fi
syncrepo

# sync full extra staff
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" || exit 1

refreshconfig

# [gigos] 显式 clone 社区 overlay:emerge --sync 不会为不存在的 location 建 git overlay,
# 而 calamares-settings-gig / flclash 等都在这些 overlay 里,不 clone 则 @world 漏装。
mkdir -p "${WORKDIR}/squashfs/var/db/repos"
for ov in "${OVERLAYS[@]}";do
    oname="${ov%%|*}"; ourl="${ov##*|}"
    odst="${WORKDIR}/squashfs/var/db/repos/${oname}"
    if [ -d "${odst}/.git" ];then
        git -C "${odst}" pull --ff-only || true
    else
        for n in 1 2 3;do
            git clone --depth=1 "${ourl}" "${odst}" && break
            [ "${n}" = 3 ] && echo "[gigos] 警告:clone overlay ${oname} 失败"
        done
    fi
done

# [gigos] @world 前(最后一次 syncrepo 之后)把 calamares-settings-gig 的 9999 ebuild(git-r3)
# 指向我们的 Gentoo-zh fork(含:装机后清自动登录/语言服务/桌面安装按钮、按 live 选择配
# nvidia、shellprocess 启用)。若在 syncrepo 前改会被 emerge --sync/git pull 重置回 Gig-OS 上游
# (其 shellprocess 注释掉=清理全不生效);放此处之后无 sync,@world 的 git-r3 即用本 URL。
CSGEB="${WORKDIR}/squashfs/var/db/repos/gig/app-admin/calamares-settings-gig/calamares-settings-gig-9999.ebuild"
if [ -f "${CSGEB}" ];then
    sed -i "s#https://github.com/Gig-OS/calamares-settings-gig.git#${CSG_FORK_URL}#" "${CSGEB}"
    echo "[gigos] calamares-settings-gig ebuild → Gentoo-zh fork(@world 前最终生效)"
else
    echo "[gigos] 致命:未找到 calamares-settings-gig 9999 ebuild → 无法指向带清理的 fork;中止构建"
    echo "        (否则会出无装机清理的盘:装好的系统残留 autologin / SSH 密码登录等 live 后门)"
    exit 1
fi

# [gigos][zfs] zfs-kmod 从源码编需 /usr/src/linux 指向 dist-kernel 构建树(.config/Module.symvers +
# /lib/modules/<ver>/build),这些符号链接由 gentoo-kernel-bin 的 pkg_postinst 建。在单次 @world 事务里
# zfs 的 pkg_setup 可能早于内核 postinst 跑 →「kernel needs to be rebuilt」失败(nvidia 走 binpkg、
# MERGE_TYPE=binary 跳过内核检查故无事)。解法:先单独 emerge gentoo-kernel-bin(postinst 立刻建好链接)、
# eselect kernel set 锁定 /usr/src/linux,之后 @world 里的 sys-fs/zfs 方能编过。
retry crun emerge -vu1q --jobs "${CORES}" sys-kernel/gentoo-kernel-bin || exit 1
crun eselect kernel set 1 || true
# objtool 可用性:gentoo-kernel-bin 自带的 objtool 动态链接 libelf + binutils-libs(libbfd,内核 ≥6.19);
# 新 chroot 里 binutils-libs 可能缺(它只是 kernel-build 的 BDEPEND、非 -bin 的 RDEPEND)→ objtool 退 127
# → linux-mod-r1 _modules_sanity_objtool 判「kernel needs to be rebuilt」使 zfs-kmod 编译失败(bug 732210)。
crun emerge -q --noreplace virtual/libelf sys-libs/binutils-libs || exit 1
# 早失败探针:objtool 仍退 127(缺 .so)立刻中止,别烧 2h 才在 zfs 处炸。
crun sh -c 'O=/usr/src/linux/tools/objtool/objtool; if [ -e "$O" ]; then "$O" >/dev/null 2>&1; [ $? -eq 127 ] && { echo "[gigos] FATAL: objtool 退 127(缺 .so),zfs-kmod 将失败"; ldd "$O"; exit 1; }; fi; echo "[gigos] objtool 可用"' || exit 1

# 升级整个系统。CONFIG_PROTECT="-*" 让 --autounmask-continue 写的 package.use 当次即生效
# (否则被 CONFIG_PROTECT 拦成 ._cfg 待处理、当次不读 → autounmask 续跑仍缺那条 → 失败)。
# FEATURES="-merge-sync" 理由同 portage 升级处。autounmask 自愈滚动树的 USE / 关键字漂移;
# FEATURES="-merge-sync" 理由同 portage 升级处。autounmask 自愈滚动树的 USE / 关键字漂移;但 python
# 目标迁移期(官方 stage3 种子仍带 3.13)那串 @system 构建后端的 3_13 桥接,portage 回溯收敛不了
# (试过 --autounmask-backtrack=y + --backtrack=300 仍早退),改由 package.use/python-transition 显式给足 USE。
retry crun CONFIG_PROTECT="-*" FEATURES="-merge-sync" emerge -uvDNq --jobs "${CORES}" --keep-going --autounmask-continue --autounmask-keep-masks=y @world || exit 1

# 显式补装 EXTRA_PKGS:@world 回溯可能把它们丢掉(如 calamares 撞 docutils 版本冲突被丢弃),
# 显式 emerge 作参数不会被丢。逐个装 + || true,一个失败不连累其他与整锅。
for pkg in "${EXTRA_PKGS[@]}";do
    retry crun CONFIG_PROTECT="-*" FEATURES="-merge-sync" emerge -uvq --usepkg=n --keep-going "${pkg}" || true
done

retry crun emerge --jobs "${CORES}" @live-rebuild || exit 1

# [gigos] ZFS 根装机就绪性自检(非致命:--keep-going 可能合理跳过 sys-boot/zfsbootmenu;真正的把关在
# 99-sanitize 的 ZBM 契约断言)。这里只在构建日志里早早标记一个会在装机时炸的 ZFS 根路径。
if [ -x "${WORKDIR}/squashfs/usr/bin/generate-zbm" ] || [ -x "${WORKDIR}/squashfs/usr/sbin/generate-zbm" ]; then
    if [ ! -f "${WORKDIR}/squashfs/usr/lib/systemd/boot/efi/linuxx64.efi.stub" ]; then
        echo "[gigos] 警告:装了 zfsbootmenu 但缺 systemd EFI stub(linuxx64.efi.stub)→ 装机时 generate-zbm 产不出单文件 EFI;确认 sys-apps/systemd 开了 boot USE(见 package.use/zfs)"
    else
        echo "[gigos] ZFS 根就绪:generate-zbm + systemd EFI stub 均在位"
    fi
else
    echo "[gigos] 警告:squashfs 内无 generate-zbm(sys-boot/zfsbootmenu 未装,可能 --keep-going 跳过)→ ZFS 根安装将不可启动(非 ZFS 安装不受影响)"
fi
# depclean / eclean 是清理步骤、不是装包。滚动 ~arch 的 subslot 严格性(如 depclean 抱怨
# pillow 需 libavif:0/16.3=)会让它解析失败退非零;旧的 || exit 1 会把整锅构建作废。清理失败
# 最多留几个孤儿包,verify-iso 仍把关完整性。@live-rebuild 保留 || exit 1(那才是真重建)。
crun emerge -c || true
crun eclean-kernel --no-bootloader-update --no-mount -n 1 || true

# run hooks in squashfs
for hook in "${WORKDIR}"/hooks/*;do
    source "${hook}" || exit 1
done

makesquashfs

buildbootfiles

# copy extra staff for iso
# include-iso 含 boot/grub/grub.cfg(整个 GRUB 启动菜单),注入失败会让
# grub-mkrescue 打包出不可启动 ISO,故必须 || exit 1 而非 || true
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-iso/* "${WORKDIR}/iso" || exit 1

buildiso

cleanmount
