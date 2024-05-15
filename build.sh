#!/bin/bash

WORKDIR="$(dirname "$(realpath "$0")")"

ARCH=amd64
MICROARCH=amd64
SUFFIX=desktop-systemd
DIST="https://ftp-osl.osuosl.org/pub/gentoo/releases/${ARCH}/autobuilds"
TMPFS="128G"

function crun () {
	"${WORKDIR}"/arch-scripts/arch-chroot "${WORKDIR}/squashfs" bash -c "$*"
}

# ctrl+c anytime to stop
trap "exit" INT

# must run as root
if (( EUID != 0 ));then
    echo 'This script must be run with root privileges'
    exit 1
fi

# Download the stage3
mkdir -p "${WORKDIR}/squashfs"

wget -q "${DIST}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" -O "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt"
STAGE3PATH="$(sed -n '6p' "${WORKDIR}/latest-stage3-${MICROARCH}-${SUFFIX}.txt" | cut -f 1 -d ' ')"
echo "STAGE3PATH:" "${STAGE3PATH}"
STAGE3="$(basename "${STAGE3PATH}")"

if ( ! grep 'stage3downloadok' "${WORKDIR}/stat" );then
    rm -rf "squashfs/${STAGE3}"
    wget -q "${DIST}/${STAGE3PATH}" -O "squashfs/${STAGE3}" \
        && echo 'stage3downloadok' >> "${WORKDIR}/stat" || exit 1
fi

# unpack stage3
pushd "${WORKDIR}/squashfs" || exit 1
if ( ! grep 'unpackok' "${WORKDIR}/stat" );then
    tar xpf "${STAGE3}" --xattrs-include='*.*' --numeric-owner \
        && echo 'unpackok' >> "${WORKDIR}/stat" || exit 1
fi
popd || exit 1

# check arch-chroot tools
if [ ! -f "${WORKDIR}/arch-scripts/arch-chroot.in" ];then
    git submodule update --init --recursive || exit 1
fi
if [ ! -x "${WORKDIR}/arch-scripts/arch-chroot" ];then
    pushd "${WORKDIR}/arch-scripts" || exit 1
    make || exit 1
    popd || exit 1
fi

# DNS
cp --dereference /etc/resolv.conf "${WORKDIR}/squashfs"/etc/

# copy extra staff for squashfs
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/"

# sync portage & update world
crun emerge-webrsync || true
# try three times to sync
for n in {1..3};do
    if (crun emerge --sync);then
        break;
    fi
    if [ "${n}" == "3" ];then
        exit 1
    fi
done
if ( ! findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
    crun mount -t tmpfs -o size="${TMPFS}",uid=portage,gid=portage,mode=775 tmpfs /var/tmp/portage
elif ( findmnt "${WORKDIR}/squashfs/var/tmp/portage" ) && [ -n "${TMPFS}" ];then
    crun mount -o remount,size="${TMPFS}" /var/tmp/portage
fi
crun emerge -uvDN @world || exit 1

# run hooks in squashfs
for hook in "${WORKDIR}"/hooks/*;do
    source "${hook}" || exit 1
done

# make squashfs
mkdir -p "${WORKDIR}/iso/LiveOS"
rm -f "${WORKDIR}/iso/LiveOS/squashfs.img"
mksquashfs "${WORKDIR}/squashfs/" "${WORKDIR}/iso/LiveOS/squashfs.img" -wildcards -ef exclude.txt -b 1024K -comp xz -progress -processors 4 -Xdict-size 100% || exit 1

# make initramfs with live support
KVER="$(ls "${WORKDIR}/squashfs/lib/modules" | sort -Vr | head -n1)"
crun dracut -f --kver "${KVER}" --add dmsquash-live --add dmsquash-live-autooverlay || exit 1

# copy the kernel to iso workdir
mkdir -p "${WORKDIR}/iso/boot"
cp -v "${WORKDIR}/squashfs/boot/kernel-${KVER}" "${WORKDIR}/iso/boot/kernel" || exit 1
cp -v "${WORKDIR}/squashfs/boot/initramfs-${KVER}.img" "${WORKDIR}/iso/boot/initrd" || exit 1

# copy extra staff for iso
rsync -rl --copy-unsafe-links "${WORKDIR}"/include-iso/* "${WORKDIR}/iso" || true

# bind iso dir to rootfs to make iso
if ( ! findmnt "${WORKDIR}/squashfs/mnt/gen-iso" );then
    mkdir -p "${WORKDIR}/squashfs/mnt/gen-iso"
    mount --bind "${WORKDIR}" "${WORKDIR}/squashfs/mnt/gen-iso"
fi
crun grub-mkrescue -o /mnt/gen-iso/gig-os.iso /mnt/gen-iso/iso -- -as mkisofs -V 'Gig-OS'
