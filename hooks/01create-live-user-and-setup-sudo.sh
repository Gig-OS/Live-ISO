#!/bin/bash

# add live user with 'live' as password
crun useradd -m live -p '$6$9PnXcWXTMZPm2w/y$vLDpBiW5PLHPD.pC4wN8N5fwNJJ9Q1xWmZwTb0tPLvUYHkUl8bmb5Yxn0HRP9F.GIuWk7o3SsEewyXhsW9EL.1'

# add to wheel to use sudo
crun gpasswd -a live wheel

crun sed -i 's/.*%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' /etc/sudoers
