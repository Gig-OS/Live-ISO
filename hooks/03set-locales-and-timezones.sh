#!/bin/bash

echo "Asia/Shanghai" > ${WORKDIR}/squashfs/etc/timezone
crun emerge --config sys-libs/timezone-data

if ( ! grep -q ^zh_CN.UTF-8 ${WORKDIR}/squashfs/etc/locale.gen );then
    # 三个 locale 供 grub 开机菜单经 locale.LANG= 切换语言。
    echo -e "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\nzh_TW.UTF-8 UTF-8" >> ${WORKDIR}/squashfs/etc/locale.gen
    crun locale-gen
    # 并行 locale-gen 偶发漏编 zh_CN 与 zh_TW 这类大 CJK locale，导致下一步 eselect locale set
    # 报 `Target 无效` 而中止本次构建。故无条件再用串行 localedef 补齐并校验，已编出的会被覆盖。
    crun bash -c '
        for l in en_US zh_CN zh_TW; do localedef -i "$l" -f UTF-8 "${l}.UTF-8" || true; done
        for l in en_US zh_CN zh_TW; do locale -a | grep -qix "${l}.utf8" || { echo "[gigos] locale ${l}.utf8 生成失败"; exit 1; }; done
    '
    # live 默认简体中文，繁体与英文由 grub 菜单传 locale.LANG= 覆盖。
    crun eselect locale set zh_CN.utf8
fi
