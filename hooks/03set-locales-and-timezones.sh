#!/bin/bash

echo "Asia/Shanghai" > ${WORKDIR}/squashfs/etc/timezone
crun emerge --config sys-libs/timezone-data

if ( ! grep -q ^zh_CN.UTF-8 ${WORKDIR}/squashfs/etc/locale.gen );then
    # 生成 en_US / zh_CN / zh_TW 三个 locale,供 grub 开机选语言(locale.LANG=)切换
    echo -e "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\nzh_TW.UTF-8 UTF-8" >> ${WORKDIR}/squashfs/etc/locale.gen
    crun locale-gen
    # 兜底:并行 locale-gen(4 worker)偶发漏编大 CJK locale(zh_CN/zh_TW),致下一步
    # eselect set zh_CN.utf8 报「Target 无效」→ 整锅炸(见 build-20260615-013814)。
    # 无条件用串行 localedef 补齐并校验三个 locale(单 locale 内存小、确定性高;已编则覆盖,无害)。
    crun bash -c '
        for l in en_US zh_CN zh_TW; do localedef -i "$l" -f UTF-8 "${l}.UTF-8" || true; done
        for l in en_US zh_CN zh_TW; do locale -a | grep -qix "${l}.utf8" || { echo "[gigos] locale ${l}.utf8 生成失败"; exit 1; }; done
    '
    # live 默认简体中文;繁体/英文由 grub 菜单传 locale.LANG= 覆盖
    crun eselect locale set zh_CN.utf8
fi
