#!/bin/bash

# add live user with 'live' as password
crun userdel -r live || true
crun useradd -m -c Live live 
crun 'echo -e "live\nlive" | passwd live'
crun 'echo -e "live\nlive" | passwd'

# add to wheel to use sudo
crun gpasswd -a live wheel

# 加入 video / render 组:nvidia 设备节点是 root:video(0660)、DRI 渲染节点是 root:render。
# 不加的话 live 连不上 nvidia(nvidia-smi/OpenGL 报 "couldn't communicate")、用不了硬件加速。
crun gpasswd -a live video
crun gpasswd -a live render

sed -i 's/.*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${WORKDIR}/squashfs/etc/sudoers"
