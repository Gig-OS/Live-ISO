#!/bin/bash
# live「闭源 NVIDIA」启动项(grub 传 gigos.gpu=nvidia)在登录管理器前【常规加载】nvidia。
# 不走 early KMS(不进 initramfs)——开机后正常 modprobe 四件套 + 建设备节点,udev 此时已就绪、
# 节点正常创建。比 early KMS 简单可靠(Arch/Gentoo wiki 推荐的常规做法)。
# 仅 gigos.gpu=nvidia 命中(由 .service 的 ConditionKernelCommandLine 守卫;开源/AMD/Intel 项不动)。
[ -d /sys/module/nvidia ] && exit 0      # 已加载则跳过(幂等)
modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>/dev/null || true
# 建 /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm(+tools) /dev/nvidia-modeset
nvidia-modprobe -c 0 -u -m 2>/dev/null || true
exit 0
