#!/bin/bash

# add live user with 'live' as password
crun useradd -m live 
crun 'echo -e "live\nlive" | passwd live'
crun 'echo -e "live\nlive" | passwd'

# add to wheel to use sudo
crun gpasswd -a live wheel

sed -i 's/.*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${WORKDIR}/squashfs/etc/sudoers"
