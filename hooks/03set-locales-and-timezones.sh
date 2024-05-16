#!/bin/bash

echo "Asia/Shanghai" > ${WORKDIR}/squashfs/etc/timezone
crun emerge --config sys-libs/timezone-data

echo -e "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8" >> ${WORKDIR}/squashfs/etc/locale.gen
crun locale-gen
crun eselect locale set zh_CN.utf8
