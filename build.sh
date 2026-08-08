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

# 用 -nv 而非 -q：-q 会一并抑制错误输出，网络失败后无法从日志追查。
WGET="wget -nv --timeout=30 --tries=3 -c"

function fetchstage3 () {
    ${WGET} "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" -O "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" || exit 1
    STAGE3PATH="$(sed -n '6p' "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | cut -f 1 -d ' ')"
    echo "STAGE3PATH:" "${STAGE3PATH}"
    # STAGE3PATH 为空时 wget 会转而抓取目录索引并写出损坏的文件，故先断言非空。
    [ -n "${STAGE3PATH}" ] || { echo "解析 stage3 路径失败"; exit 1; }
    STAGE3="$(basename "${STAGE3PATH}")"

    if ( ! grep 'stage3downloadok' "${WORKDIR}/stat" );then
        rm -rf "squashfs/${STAGE3}"
        ${WGET} "${DIST}/${STAGE3PATH}" -O "squashfs/${STAGE3}" || exit 1
        # 官方 .sha256 是 PGP 包裹格式，无法直接校验，需先取出 64 位十六进制那行再交给 sha256sum -c。
        ${WGET} "${DIST}/${STAGE3PATH}.sha256" -O "squashfs/${STAGE3}.sha256" || exit 1
        ( cd squashfs && grep -E "^[0-9a-f]{64}.*$(basename "${STAGE3}")" "${STAGE3}.sha256" | sha256sum -c - ) \
            || { echo "stage3 sha256 校验失败"; exit 1; }
        rm -f "squashfs/${STAGE3}.sha256"
        echo 'stage3downloadok' >> "${WORKDIR}/stat"
    fi
}

function unpackstage3 () {
    pushd "${WORKDIR}/squashfs" || exit 1
    if ( ! grep 'unpackok' "${WORKDIR}/stat" );then
        tar xpf "${STAGE3}" --xattrs-include='*.*' --numeric-owner \
            && echo 'unpackok' >> "${WORKDIR}/stat" \
	        && rm "${STAGE3}" || exit 1
    fi
popd || exit 1
}

function buildarchscript () {
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

# 网络等瞬时失败自动重试，次数与间隔见 config。多数调用点配 binpkg 缓存，重试只重做失败的包；
# EXTRA_PKGS 那步用 --usepkg=n，重试会全量重编。
retry () {
    local n=1
    until "$@";do
        [ "${n}" -ge "${RETRY_MAX}" ] && return 1
        echo "[gigos] 第 ${n}/${RETRY_MAX} 次失败，${RETRY_DELAY}s 后重试：$*"
        n=$((n+1)); sleep "${RETRY_DELAY}"
    done
}

# 从 chroot 树的 md5-cache 读取某个包的最新 amd64-stable 版本，按 token 精确匹配以区分 amd64 与 ~amd64。
# 不用 `ACCEPT_KEYWORDS=amd64 emerge`：ACCEPT_KEYWORDS 是增量变量，与 chroot make.conf 的 `~amd64 *`
# 累加而非替换，压不住测试版。md5-cache 随 gentoo git 树自带，离线可读且与 ACCEPT_KEYWORDS 无关。
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
        # 同 overlay clone:失败会留下半截目录，不清除则后两次直接以 destination path
        # already exists 失败，重试等于只有一次。
        rm -rf "${WORKDIR}/squashfs/var/db/repos/gentoo"
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
    sed -i "s/MAKEOPTS=\".*\"/MAKEOPTS=\""${MAKEOPTS}"\"/g" "${WORKDIR}/squashfs/etc/portage/make.conf/common"

    # 不得为 GENTOO_MIRRORS 追加 /gentoo 前缀：官方源根目录没有该前缀会返回 404，
    # 只有部分 CN 镜像需要，各自在 config 中定义完整地址。
    echo "GENTOO_MIRRORS=\"${GENTOO_MIRRORS}\"" > "${WORKDIR}/squashfs/etc/portage/make.conf/mirror"
}

function mounttmpfs () {
    if [[ -n "${TMPFS}" ]];then
        crun mkdir -p /var/tmp/{notmpfs,portage}
        crun chown portage:portage /var/tmp/{notmpfs,portage}
        crun chmod 775 /var/tmp/{notmpfs,portage}
        if ( ! findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -t tmpfs -o size="${TMPFS}",uid=portage,gid=portage,mode=775 tmpfs /var/tmp/portage
        elif ( findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
            crun mount -o remount,size="${TMPFS}" /var/tmp/portage
        fi
    fi
    # 把宿主的持久缓存 bind 进 chroot，跨次构建复用 binpkg 与 distfiles；未设置这两个变量时无缓存。
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
    # 用 zstd 而非 xz：live 从 U 盘边读边解压，zstd 解压更快，而 -Xcompression-level 19
    # 的压缩率仍接近 xz。要求 squashfs-tools 开启 zstd USE。
    mksquashfs "${WORKDIR}/squashfs/" "${WORKDIR}/iso/LiveOS/squashfs.img" \
    -wildcards -ef exclude.txt -b 1024K -comp zstd -Xcompression-level 19 -progress -processors "${CORES}" || exit 1
}

function buildbootfiles () {
    KVER="$(ls "${WORKDIR}/squashfs/lib/modules" | sort -Vr | head -n1)"
    # --xz：与官方 livegui 一致，initramfs 体积更小。
    # nvidia 闭源驱动不进 initramfs，改由 gigos-nvidia-load.service 在 udev 就绪后 modprobe。
    # --omit network-manager：NM 进入 initramfs 后，NetworkManager-initrd.service 会随 switch-root
    # 带进真根，与 NetworkManager.service 争用同一 BusName，systemd 拒绝加载导致开机网络不自启。
    crun dracut --no-hostonly -f --kver "${KVER}" --xz --add dmsquash-live --add dmsquash-live-autooverlay --add crypt --omit network-manager || exit 1

    mkdir -p "${WORKDIR}/iso/boot"
    cp -v "${WORKDIR}/squashfs/boot/kernel-${KVER}" "${WORKDIR}/iso/boot/kernel" || exit 1
    cp -v "${WORKDIR}/squashfs/boot/initramfs-${KVER}.img" "${WORKDIR}/iso/boot/initrd" || exit 1
}

function buildiso () {
    if ( ! findmnt "${WORKDIR}/squashfs/mnt/gen-iso" );then
        mkdir -p "${WORKDIR}/squashfs/mnt/gen-iso"
        mount --bind "${WORKDIR}" "${WORKDIR}/squashfs/mnt/gen-iso"
    fi
    crun grub-mkrescue -o /mnt/gen-iso/gig-os-"$(date +%Y%m%d)".iso /mnt/gen-iso/iso -- -as mkisofs -V 'Gig-OS' || exit 1
}

trap cleanmount INT
trap cleanmount EXIT

if (( EUID != 0 ));then
    echo 'This script must be run with root privileges'
    exit 1
fi

# 锁放在 build.sh 而非 wrapper：直接执行 build.sh 也不会与 autobuild 争用同一份 squashfs 与缓存。
exec 9>/run/gigos-build.lock
flock -n 9 || { echo '已有构建在执行(/run/gigos-build.lock 被占用)，退出'; exit 1; }

mkdir -p "${WORKDIR}/squashfs"

fetchstage3

unpackstage3

buildarchscript

# package.use 必须在此处一并注入：留给第二次 rsync 会被增量算法漏掉，chroot 内 package.use 为空，
# calamares 依赖的 boost 与 libpwquality 缺少 python USE 而无法安装。make.conf/use 仍排除，等系统就绪再注入。
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" --exclude etc/portage/make.conf/use || exit 1

refreshconfig
mounttmpfs

# locale.conf 为 zh_CN.UTF-8，未生成该 locale 时 btrfs-progs 的 man 经 sphinx 调 setlocale('')
# 抛出 locale.Error，man 编译失败并连累依赖它的包。
# 用 localedef 而非 locale-gen：后者会一并处理内建的 C.UTF-8，纯 stage3 中无法编出，
# 以 `not all compiled` 中止本次构建。localedef 遇字符集告警也可能返回非零，故不看退出码，改为断言结果。
# 三个 locale 都要编进 locale-archive，verify-iso.sh 会逐个检查。
crun localedef -i en_US -f UTF-8 en_US.UTF-8 || true
crun localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 || true
crun localedef -i zh_TW -f UTF-8 zh_TW.UTF-8 || true
{ crun locale -a 2>/dev/null | grep -qi '^zh_CN' && crun locale -a 2>/dev/null | grep -qi '^zh_TW'; } || { echo "[gigos] 致命:zh_CN/zh_TW.UTF-8 locale 没能生成,man/sphinx 会编译失败、ISO 中文回退 C,中止"; exit 1; }
echo "[gigos] locale 就绪：$(crun locale -a 2>/dev/null | grep -iE '^en_US|^zh_CN|^zh_TW' | tr '\n' ' ')"

cp --dereference /etc/resolv.conf "${WORKDIR}/squashfs"/etc/

syncrepo

# 必须在任何 emerge 之前钉住最新 amd64-stable 的 gcc、内核与 zfs：随后的 portage/git 升级会用 -D
# 拖入 gcc，晚一步就会先安装测试版。全局 ACCEPT_KEYWORDS="~amd64 *" 默认取最新测试版，已知会拖入
# 超 OpenZFS 上限的内核、RC 版 zfs 模块与无法编译 btrfs-progs 的 gcc 快照。
# 内核不超 zfs-kmod 上限、zfs 与 zfs-kmod 同版本这两条由 99-sanitize 出厂前断言兜底。改钉版策略改这一段。
GSTAB=$(newest_stable sys-devel/gcc)
KSTAB=$(newest_stable sys-kernel/gentoo-kernel-bin)
# ZFS 有两种形态，自动判别以免上游变动后需要手改：
#   - >=2.4.1：zfs-kmod 已并入 sys-fs/zfs，一个包同时提供用户态与 zfs.ko。
#   - <=2.3.8：zfs 与 zfs-kmod 是两个包，必须同版本。
# 读 sys-fs/zfs 最新 stable 的 ebuild 判断是否已合并：合并则内核上限取自该 ebuild，未合并才退回以
# zfs-kmod 的最新 stable 为准。这样 zfs-kmod 将来被移出树也不会让本次构建失败。
ZSTAB=$(newest_stable sys-fs/zfs)
ZEB="${WORKDIR}/squashfs/var/db/repos/gentoo/sys-fs/zfs/zfs-${ZSTAB}.ebuild"
if [ -n "${ZSTAB}" ] && grep -q 'MODULES_OPTIONAL_IUSE' "${ZEB}" 2>/dev/null; then
    ZFS_MERGED=1
    ZKMAX=$(grep -oE 'MODULES_KERNEL_MAX=[0-9.]+' "${ZEB}" 2>/dev/null | head -1 | cut -d= -f2)
else
    ZFS_MERGED=0
    ZSTAB=$(newest_stable sys-fs/zfs-kmod)
    ZKMAX=$(grep -oE 'MODULES_KERNEL_MAX=[0-9.]+' "${WORKDIR}/squashfs/var/db/repos/gentoo/sys-fs/zfs-kmod/zfs-kmod-${ZSTAB}.ebuild" 2>/dev/null | head -1 | cut -d= -f2)
fi
[ -n "${KSTAB}" ] && [ -n "${ZSTAB}" ] && [ -n "${GSTAB}" ] || { echo "[gigos] 致命：算不出 amd64-stable 内核/zfs/gcc 版本(md5-cache 无法读取？树未同步？)，中止"; exit 1; }
KMM=$(echo "${KSTAB}" | cut -d. -f1-2)
echo "[gigos] 动态 stable 钉版:gcc ${GSTAB}、内核 ${KSTAB}、zfs ${ZSTAB}($([ "${ZFS_MERGED}" = 1 ] && echo '已合并 kmod' || echo "另配 zfs-kmod ${ZSTAB}"),内核上限 ${ZKMAX:-未知})"
if [ -n "${ZKMAX}" ] && [ "$(printf '%s\n%s\n' "${ZKMAX}" "${KMM}" | sort -V | tail -1)" = "${KMM}" ] && [ "${KMM}" != "${ZKMAX}" ];then
    echo "[gigos] 警告:stable 内核 ${KMM} 超过 OpenZFS 上限 ${ZKMAX},zfs 模块可能无法编译(靠 99-sanitize 断言兜底)"
fi
mkdir -p "${WORKDIR}/squashfs/etc/portage/package.mask"
cat > "${WORKDIR}/squashfs/etc/portage/package.mask/kernel-zfs" <<MASKEOF
# 本文件由 build.sh 每次动态生成，钉住最新 amd64-stable 的 gcc、内核与 zfs，无需手工维护。
# 本次算得：gcc ${GSTAB}、内核 ${KSTAB}、zfs ${ZSTAB}。修改方法见 build.sh 中生成本文件的那段。
# sys-fs/zfs[dist-kernel] 依赖无版本的 virtual/dist-kernel，-uD @world 会选版本最高的 provider，
# 所以每个 provider 都要钉，漏一个就会装出第二个超 OpenZFS 上限、没有 zfs.ko 的内核。
# gentoo-kernel-modprep 只铺模块树不装 vmlinuz，被选中时 linux-firmware 的 postinst 会因此失败。
>sys-devel/gcc-${GSTAB}
>sys-kernel/gentoo-kernel-bin-${KSTAB}
>sys-kernel/gentoo-kernel-${KSTAB}
>sys-kernel/gentoo-sources-${KSTAB}
>sys-kernel/vanilla-kernel-${KSTAB}
>sys-kernel/gentoo-kernel-modprep-${KSTAB}
>virtual/dist-kernel-${KSTAB}
>sys-fs/zfs-${ZSTAB}
MASKEOF
# 只有旧拆分结构才需要连 zfs-kmod 一起钉，合并版没有这个包。
[ "${ZFS_MERGED}" = 1 ] || echo ">sys-fs/zfs-kmod-${ZSTAB}" >> "${WORKDIR}/squashfs/etc/portage/package.mask/kernel-zfs"

# FEATURES="-merge-sync"：portage 3.0.79 自升级时 _post_merge_sync 引用新版才有的 _SyncfsProcess
# 模块，运行中的旧 portage 没有该模块，抛 ModuleNotFoundError 导致安装失败。
# merge-sync 只用于防断电丢数据，对 tmpfs 全内存构建无意义。
retry crun FEATURES="-merge-sync" emerge -vu1q --jobs "${CORES}" portage
# 同步 overlay 需要 git。这步是 -uD 深度解算，会拖入 @system 的一批构建后端，滚动树漂移时可能要求
# 新的 USE，故给与 @world 相同的自愈参数：autounmask 把 USE 写入 zz-autounmask 后继续，
# CONFIG_PROTECT="-*" 让写入当次即生效（否则落成 ._cfg，续行时仍缺该条），
# --autounmask-keep-masks=y 保证不掀掉钉 stable 的 package.mask。zz-autounmask 由 99-sanitize 出厂前清除。
if ( ! crun which git);then
    crun CONFIG_PROTECT="-*" emerge -vuDq --jobs "${CORES}" --autounmask-continue --autounmask-keep-masks=y dev-vcs/git || exit 1
fi

# 因为上一步是 -uD 深度升级，dev-lang/perl 常在此升到新的大版本，旧版本目录下的 perl 模块对新 perl
# 不可见：help2man 无法取得 Locale::gettext，会让 app-crypt/sbsigntools（gentoo-kernel-bin 的
# secureboot 依赖）在生成 man 页时编译失败并中止本次构建。故在后续所有 emerge 之前先按新 perl 重建模块。
crun "command -v perl-cleaner >/dev/null 2>&1 || emerge -1q app-admin/perl-cleaner" || true
crun "perl-cleaner --all -- --jobs ${CORES} -q" || true

syncrepo

rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" || exit 1

refreshconfig

# 必须显式 clone 社区 overlay：emerge --sync 不会为不存在的 location 创建 git overlay，
# 而 calamares-settings-gig 与 flclash 等包都在这些 overlay 中，不 clone 则 @world 漏装。
mkdir -p "${WORKDIR}/squashfs/var/db/repos"
for ov in "${OVERLAYS[@]}";do
    oname="${ov%%|*}"; ourl="${ov##*|}"
    odst="${WORKDIR}/squashfs/var/db/repos/${oname}"
    if [ -d "${odst}/.git" ];then
        git -C "${odst}" pull --ff-only || true
    else
        for n in 1 2 3;do
            # 失败会留下半截目录，不清除则后两次 clone 直接以 destination path
            # already exists 失败，重试等于只有一次。
            rm -rf "${odst}"
            git clone --depth=1 "${ourl}" "${odst}" && break
            [ "${n}" = 3 ] && echo "[gigos] 警告:clone overlay ${oname} 失败"
        done
    fi
done

# 把 calamares-settings-gig 的 9999 ebuild（git-r3）指向 Gentoo-zh fork，该 fork 含装机后清除
# 自动登录与桌面按钮、按 live 选择配置 nvidia、启用 shellprocess。
# 必须放在最后一次 syncrepo 之后、@world 之前：更早会被 emerge --sync 或 git pull 重置回 Gig-OS
# 上游，而上游注释掉了 shellprocess，装机清理完全不生效。
CSGEB="${WORKDIR}/squashfs/var/db/repos/gig/app-admin/calamares-settings-gig/calamares-settings-gig-9999.ebuild"
if [ -f "${CSGEB}" ];then
    sed -i "s#https://github.com/Gig-OS/calamares-settings-gig.git#${CSG_FORK_URL}#" "${CSGEB}"
    echo "[gigos] calamares-settings-gig ebuild → Gentoo-zh fork(@world 前最终生效)"
else
    echo "[gigos] 致命：未找到 calamares-settings-gig 9999 ebuild → 无法指向带清理的 fork;中止构建"
    echo "        (否则会出无装机清理的盘：装好的系统残留 autologin / SSH 密码登录等 live 后门)"
    exit 1
fi

# zfs-kmod 从源码编译需要 /usr/src/linux 指向 dist-kernel 构建树，该链接由 gentoo-kernel-bin 的
# pkg_postinst 建立。单次 @world 事务中 zfs 的 pkg_setup 可能早于内核 postinst 执行并报
# `kernel needs to be rebuilt`，故先单独 emerge gentoo-kernel-bin 再用 eselect 锁定 /usr/src/linux。
# nvidia 走 binpkg，MERGE_TYPE=binary 跳过内核检查，不受影响。
retry crun emerge -vu1q --jobs "${CORES}" sys-kernel/gentoo-kernel-bin || exit 1
crun eselect kernel set 1 || true
# gentoo-kernel-bin 自带的 objtool 动态链接 libelf 与 binutils-libs（libbfd，内核 >=6.19）。
# binutils-libs 只是 kernel-build 的 BDEPEND、不是 -bin 的 RDEPEND，新 chroot 中可能缺失，
# 导致 objtool 退 127，linux-mod-r1 的 _modules_sanity_objtool 判为 `kernel needs to be rebuilt`
# 而使 zfs-kmod 编译失败（bug 732210）。
crun emerge -q --noreplace virtual/libelf sys-libs/binutils-libs || exit 1
# 早失败探针：objtool 仍退 127（缺 .so）时立刻中止，避免两小时后才在 zfs 处失败。
crun sh -c 'O=/usr/src/linux/tools/objtool/objtool; if [ -e "$O" ]; then "$O" >/dev/null 2>&1; [ $? -eq 127 ] && { echo "[gigos] FATAL: objtool 退 127(缺 .so),zfs-kmod 将失败"; ldd "$O"; exit 1; }; fi; echo "[gigos] objtool 可用"' || exit 1

# CONFIG_PROTECT="-*" 让 --autounmask-continue 写的 package.use 当次即生效（否则落成 ._cfg，
# 当次不读取，续行时仍缺该条而失败）。FEATURES="-merge-sync" 理由同 portage 升级处。
# autounmask 只能自愈滚动树的 USE 与关键字漂移；python 目标迁移期 @system 构建后端的 3_13 桥接
# portage 回溯收敛不了，--autounmask-backtrack=y 加 --backtrack=300 仍会早退，
# 改由 package.use/python-transition 显式给足 USE。
# 提供内核模块的包只能本机编：远端 binhost 是对着 gentoo-kernel 编的，本盘装 gentoo-kernel-bin，KV 不同。
# 出 .ko 的只有 sys-fs/zfs 与 x11-drivers/nvidia-drivers，新增这类包时记得加进来。
WORLD_EMERGE='CONFIG_PROTECT="-*" FEATURES="-merge-sync" emerge -uvDNq --jobs '"${CORES}"' --keep-going --usepkg-exclude "sys-fs/zfs sys-fs/zfs-kmod x11-drivers/nvidia-drivers" --autounmask-continue --autounmask-keep-masks=y @world'
# 因为 dev-lang/perl 可能在本次 @world 中途升级，升级后旧版本目录下的模块对新 perl 不可见：
# help2man 无法取得 Locale::gettext，app-crypt/sbsigntools 这类用它生成 man 页的包编译失败，
# --keep-going 下最终 emerge 仍返回非零并中止本次构建。故第一次 @world 失败时先重建 perl 模块再重试。
if ! crun "${WORLD_EMERGE}"; then
    # @world 期间可能再次升级 perl，故失败后再重建一次模块并重试。
    echo "[gigos] @world 未全部成功，重建 perl 模块后重试"
    crun "perl-cleaner --all -- --jobs ${CORES} -q" || true
    retry crun "${WORLD_EMERGE}" || exit 1
fi

# @world 回溯可能丢弃 EXTRA_PKGS 中的包（例如 calamares 与 docutils 版本冲突时被丢弃），
# 作为显式参数 emerge 则不会。逐个安装并配 || true，一个失败不连累其他包与本次构建。
for pkg in "${EXTRA_PKGS[@]}";do
    retry crun CONFIG_PROTECT="-*" FEATURES="-merge-sync" emerge -uvq --usepkg=n --keep-going "${pkg}" || true
done

retry crun emerge --jobs "${CORES}" @live-rebuild || exit 1

# ZFS 根装机就绪性自检，非致命：--keep-going 可能合理跳过 sys-boot/zfsbootmenu，真正的把关在
# 99-sanitize 的 ZBM 契约断言。此处只在构建日志中提前标记会在装机时失败的 ZFS 根路径。
if [ -x "${WORKDIR}/squashfs/usr/bin/generate-zbm" ] || [ -x "${WORKDIR}/squashfs/usr/sbin/generate-zbm" ]; then
    if [ ! -f "${WORKDIR}/squashfs/usr/lib/systemd/boot/efi/linuxx64.efi.stub" ]; then
        echo "[gigos] 警告：装了 zfsbootmenu 但缺 systemd EFI stub(linuxx64.efi.stub)→ 装机时 generate-zbm 产不出单文件 EFI;确认 sys-apps/systemd 开了 boot USE(见 package.use/zfs)"
    else
        echo "[gigos] ZFS 根就绪:generate-zbm + systemd EFI stub 均在位"
    fi
else
    echo "[gigos] 警告:squashfs 内无 generate-zbm(sys-boot/zfsbootmenu 未装，可能 --keep-going 跳过)→ ZFS 根安装将不可启动(非 ZFS 安装不受影响)"
fi
# depclean 与 eclean 是清理步骤而非安装。滚动 ~arch 的 subslot 严格性（例如 depclean 要求
# pillow 依赖 libavif:0/16.3=）会让解析失败并返回非零，用 || exit 1 会作废整次构建。
# 清理失败最多留下几个孤儿包，完整性仍由 verify-iso 把关。@live-rebuild 是真正的重建，保留 || exit 1。
crun emerge -c || true
crun eclean-kernel --no-bootloader-update --no-mount -n 1 || true

for hook in "${WORKDIR}"/hooks/*;do
    source "${hook}" || exit 1
done

makesquashfs

buildbootfiles

# include-iso 含 boot/grub/grub.cfg，即整个 GRUB 启动菜单，注入失败会让 grub-mkrescue
# 打包出不可启动的 ISO，故必须用 || exit 1 而非 || true。
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-iso/* "${WORKDIR}/iso" || exit 1

buildiso

cleanmount
