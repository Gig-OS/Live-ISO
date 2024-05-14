#!/bin/bash

crun echo "Asia/Shanghai" > /etc/timezone
crun emerge --config sys-libs/timezone-data

crun echo -e "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8" >> /etc/locale.gen
crun locale-gen
crun eselect locale set zh_CN.utf8
