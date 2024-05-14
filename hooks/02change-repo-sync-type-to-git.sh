#!/bin/bash

if ( chroot "${WORKDIR}"/squashfs which git ) && [ ! -d "${WORKDIR}"/squashfs/var/db/repos/gentoo/.git ];then
    crun rm -rf /var/db/repos/gentoo
    crun emerge --sync
fi
