#!/bin/bash

if [ ! -d "${WORKDIR}"/squashfs/var/db/repos/gentoo/.git ];then
    crun rm -rf /var/db/repos/gentoo
    crun emerge --sync
fi
