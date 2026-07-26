#!/bin/bash
# 双显卡驱动收尾:x11-drivers/nvidia-drivers 的 ebuild 会在
# /etc/modprobe.d/nvidia.conf 写一行 "blacklist nouveau",静态禁掉 nouveau。
# 但本 ISO/系统默认用 nouveau(开箱即亮,兼容性最好),闭源 nvidia 仅作可选:
# 由 grub 的「闭源 NVIDIA 驱动」启动项用内核命令行
# (modprobe.blacklist=nouveau nvidia-drm.modeset=1)按需启用。
# 故必须注释掉这条静态黑名单,否则默认开机 nouveau 起不来 → 黑屏。
NVCONF="${WORKDIR}/squashfs/etc/modprobe.d/nvidia.conf"
if [ -f "${NVCONF}" ]; then
    sed -i 's/^[[:space:]]*blacklist[[:space:]]\+nouveau/#&/' "${NVCONF}"
    echo "[04nvidia] 已注释 nvidia.conf 的 blacklist nouveau(默认 nouveau,nvidia 由 grub 项启用)"
else
    echo "[04nvidia] 未找到 ${NVCONF}(nvidia-drivers 可能没装,跳过)"
fi
