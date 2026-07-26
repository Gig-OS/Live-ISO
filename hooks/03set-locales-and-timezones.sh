#!/bin/bash

echo "Asia/Shanghai" > ${WORKDIR}/squashfs/etc/timezone
crun emerge --config sys-libs/timezone-data

if ( ! grep -q ^zh_CN.UTF-8 ${WORKDIR}/squashfs/etc/locale.gen );then
    # 生成 en_US / zh_CN / zh_TW 三个 locale,供 grub 开机选语言(locale.LANG=)切换
    echo -e "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\nzh_TW.UTF-8 UTF-8" >> ${WORKDIR}/squashfs/etc/locale.gen
    crun locale-gen
    # live 默认简体中文;繁体/英文由 grub 菜单传 locale.LANG= 覆盖
    crun eselect locale set zh_CN.utf8
fi
