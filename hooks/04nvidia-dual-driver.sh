#!/bin/bash
# x11-drivers/nvidia-drivers 会在 /etc/modprobe.d/nvidia.conf 写入 `blacklist nouveau`，静态禁用 nouveau。
# 本 ISO 默认使用 nouveau，闭源 nvidia 仅由 grub 的闭源启动项经内核命令行
# （modprobe.blacklist=nouveau nvidia-drm.modeset=1）按需启用。
# 必须注释掉这条静态黑名单，否则默认启动时 nouveau 无法加载并黑屏。
NVCONF="${WORKDIR}/squashfs/etc/modprobe.d/nvidia.conf"
if [ -f "${NVCONF}" ]; then
    sed -i 's/^[[:space:]]*blacklist[[:space:]]\+\(nouveau\|nova_core\)/#&/' "${NVCONF}"
    echo "[04nvidia] 已注释 nvidia.conf 的 blacklist nouveau 与 nova_core(默认开源驱动,nvidia 由 grub 项启用)"
else
    echo "[04nvidia] 未找到 ${NVCONF}(nvidia-drivers 可能没装，跳过)"
fi
