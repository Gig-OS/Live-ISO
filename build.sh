#!/bin/bash

WORKDIR="$(dirname "$(realpath "$0")")"

source "${WORKDIR}"/config

function cleanmount () {
    umount -l "${WORKDIR}/squashfs/var/tmp/portage" || true
    umount -l "${WORKDIR}/squashfs/mnt/gen-iso" || true
    exit
}

function fetchstage3 () {
    wget -q "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" -O "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt"
    STAGE3PATH="$(sed -n '6p' "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | cut -f 1 -d ' ')"
    echo "STAGE3PATH:" "${STAGE3PATH}"
    STAGE3="$(basename "${STAGE3PATH}")"

    if ( ! grep 'stage3downloadok' "${WORKDIR}/stat" );then
        rm -rf "squashfs/${STAGE3}"
        wget -q "${DIST}/${STAGE3PATH}" -O "squashfs/${STAGE3}" \
            && echo 'stage3downloadok' >> "${WORKDIR}/stat" || exit 1
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

# Retry a command up to 3 times. Network hiccups (mirror timeouts, transient
# fetch failures) should not kill a multi-hour build.
function retry () {
    local n
    for n in 1 2 3; do
        "$@" && return 0
        [ "${n}" = 3 ] && return 1
        echo "[build] attempt ${n} failed, retrying in 30s: $*"
        sleep 30
    done
}

# Newest amd64-STABLE version of a package, read straight from the synced tree's
# md5-cache. We cannot ask portage with ACCEPT_KEYWORDS=amd64: ACCEPT_KEYWORDS is
# an incremental variable, so an env value is *combined* with make.conf's
# "~amd64 *" instead of replacing it, and portage still picks the testing one.
# md5-cache is committed in the git tree, so a git-cloned repo already has it.
# The awk matches a bare "amd64" keyword token, never "~amd64".
function newest_stable () {
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

    # refresh MIRROR
    echo "GENTOO_MIRRORS=\""${MIRROR}"/gentoo\"" > "${WORKDIR}/squashfs/etc/portage/make.conf/mirror"
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
}

function makesquashfs (){
    mkdir -p "${WORKDIR}/iso/LiveOS"
    rm -f "${WORKDIR}/iso/LiveOS/squashfs.img"
    mksquashfs "${WORKDIR}/squashfs/" "${WORKDIR}/iso/LiveOS/squashfs.img" \
    -wildcards -ef exclude.txt -b 1024K -comp xz -progress -processors "${CORES}" -Xdict-size 100% || exit 1
}

function buildbootfiles () {
    # make initramfs with live support
    KVER="$(ls "${WORKDIR}/squashfs/lib/modules" | sort -Vr | head -n1)"
    crun dracut --no-hostonly -f --kver "${KVER}" --add dmsquash-live --add dmsquash-live-autooverlay --add crypt || exit 1

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

# Download the stage3
mkdir -p "${WORKDIR}/squashfs"

fetchstage3

unpackstage3

buildarchscript

# copy extra staff to squashfs but package.use
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" --exclude etc/portage/package.use/ --exclude etc/portage/make.conf/use

refreshconfig
mounttmpfs

# DNS
cp --dereference /etc/resolv.conf "${WORKDIR}/squashfs"/etc/

syncrepo

# Pin the toolchain and the kernel to the newest amd64-STABLE versions.
#
# make.conf sets ACCEPT_KEYWORDS="~amd64 *", so by default every emerge grabs the
# newest *testing* version of everything. For a release image that is a recurring
# source of breakage: we have had a gcc-16 snapshot fail to compile btrfs-progs,
# and testing point-release kernels churn on every build. Neither is something an
# ISO shipped to users should ride on.
#
# So right after the first tree sync (and before *any* emerge - the deep
# "emerge -uD dev-vcs/git" below already pulls the toolchain in) we compute the
# newest stable version of each and mask everything above it. Nothing is written
# by hand, so this needs no maintenance as new stable versions land.
#
# vanilla-kernel has to be masked too: sys-fs/zfs and friends depend on the
# *unversioned* virtual/dist-kernel, and -uD @world satisfies that virtual with
# the highest-versioned provider. With only gentoo-kernel-bin pinned, the
# resolver happily pulls vanilla-kernel as a second, testing kernel.
GSTAB=$(newest_stable sys-devel/gcc)
KSTAB=$(newest_stable sys-kernel/gentoo-kernel-bin)
[ -n "${GSTAB}" ] && [ -n "${KSTAB}" ] || { echo "[build] fatal: cannot determine amd64-stable gcc/kernel (tree not synced?)"; exit 1; }
echo "[build] pinning to amd64-stable: gcc ${GSTAB}, kernel ${KSTAB}"
mkdir -p "${WORKDIR}/squashfs/etc/portage/package.mask"
cat > "${WORKDIR}/squashfs/etc/portage/package.mask/stable-pin" <<MASKEOF
# Generated by build.sh on every run: pin gcc and the kernel to the newest
# amd64-stable versions and mask the testing versions above them.
# This run resolved: gcc ${GSTAB}, kernel ${KSTAB}.
>sys-devel/gcc-${GSTAB}
>sys-kernel/gentoo-kernel-bin-${KSTAB}
>sys-kernel/gentoo-kernel-${KSTAB}
>sys-kernel/gentoo-sources-${KSTAB}
>sys-kernel/vanilla-kernel-${KSTAB}
MASKEOF

# upgrade portage first
retry crun emerge -vu1q --jobs "${CORES}" portage
# we need git to sync overlay
if ( ! crun which git);then
    # -uD drags the whole @system build-backend chain into the resolve, so a USE
    # drift in the rolling tree can kill the build here. Let autounmask write the
    # flags and continue, same as the @world step below. CONFIG_PROTECT="-*" makes
    # the written package.use take effect in this same run; --autounmask-keep-masks
    # keeps the stable pin above intact.
    crun CONFIG_PROTECT="-*" emerge -vuDq --jobs "${CORES}" --autounmask-continue --autounmask-keep-masks=y dev-vcs/git || exit 1
fi
syncrepo

# sync full extra staff
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/"

refreshconfig

# upgrade system
retry crun CONFIG_PROTECT="-*" emerge -uvDNq --jobs "${CORES}" --keep-going --autounmask-continue --autounmask-keep-masks=y @world || exit 1
crun emerge --jobs "${CORES}" @live-rebuild || exit 1
crun emerge -c || exit 1
crun eclean-kernel --no-bootloader-update --no-mount -n 1 || exit 1
crun eclean-pkg || true

# run hooks in squashfs
for hook in "${WORKDIR}"/hooks/*;do
    source "${hook}" || exit 1
done

makesquashfs

buildbootfiles

# copy extra staff for iso
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-iso/* "${WORKDIR}/iso" || true

buildiso

cleanmount
