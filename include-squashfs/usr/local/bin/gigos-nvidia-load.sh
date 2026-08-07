#!/bin/bash
# live 的闭源 NVIDIA 启动项在登录管理器启动前加载 nvidia，由 .service 的
# ConditionKernelCommandLine 守卫 `gigos.gpu=nvidia`，开源、AMD、Intel 启动项不触发。
# 不走 early KMS，因此不进 initramfs；开机后 udev 已就绪，modprobe 与设备节点创建都正常。
[ -d /sys/module/nvidia ] && exit 0
modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>/dev/null || true
nvidia-modprobe -c 0 -u -m 2>/dev/null || true
exit 0
