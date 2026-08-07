#!/bin/bash

crun userdel -r live || true
crun useradd -m -c Live live 
crun 'echo -e "live\nlive" | passwd live'
crun 'echo -e "live\nlive" | passwd'

crun gpasswd -a live wheel

# nvidia 设备节点属 root:video（0660）、DRI 渲染节点属 root:render，
# 不加入这两个组时 live 用户无法访问 nvidia，nvidia-smi 与 OpenGL 报 "couldn't communicate"，硬件加速不可用。
crun gpasswd -a live video
crun gpasswd -a live render

sed -i 's/.*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${WORKDIR}/squashfs/etc/sudoers"
