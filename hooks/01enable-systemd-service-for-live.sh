#!/bin/bash

crun systemctl enable NetworkManager
# NetworkManager-initrd.service 与 NetworkManager.service 都声明 BusName=org.freedesktop.NetworkManager，
# dmsquash-live 由 initrd 切到真根后两者同时加载，systemd 报 "Two services allocated for the same bus
# name, refusing operation"，NetworkManager.service 开机加载失败、网络不自启，需手动重启服务。
# 本地介质启动的 live 与装机系统不需要 initrd 内联网络，屏蔽即可。
# 另见 buildbootfiles 的 dracut --omit network-manager，从源头不把 NM 放进 initramfs。
crun systemctl mask NetworkManager-initrd.service

# live 默认 Factory 时区，时钟未同步会影响 https 证书校验、emerge-webrsync 的 gpg 验证与 ZFS 快照时间戳。
crun systemctl enable systemd-timesyncd.service

crun systemctl enable sddm

# PipeWire 是 per-user 服务，用 --global 为所有用户建立 user-unit 软链。
# 三者必须一起启用：wireplumber 是会话管理器，pipewire-pulse 提供 KDE 音量控件所需的 PulseAudio 兼容，
# 缺任一项 live 桌面均无声。装好的系统同样需要声音，故不放进 calamares 清理。
crun systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# 读 gigos.lang= 内核参数，在 sddm 之前设定 locale 与 Plasma 语言。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-live-lang.sh"
crun systemctl enable gigos-live-lang.service

# live 与装好的系统每次启动都按真机 CPU 覆盖 make.conf/cpuflags。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-cpuflags.sh"
crun systemctl enable gigos-cpuflags.service

# GENTOO_MIRRORS 按系统语言选就近镜像：简体对应大陆、繁体对应台港、英文对应全球。
# 与 gigos-cpuflags 同一机制：出厂带标记基线，开机按语言覆盖 make.conf/mirror，用户删除标记即停止覆盖。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-mirror.sh"
crun systemctl enable gigos-mirror.service

# 闭源 nvidia 启动项传 gigos.gpu=nvidia，开机后 modprobe nvidia 四个模块并建立设备节点，不走 early KMS。
# 由服务的 ConditionKernelCommandLine 守卫，开源、AMD 与 Intel 启动项不会命中。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-nvidia-load.sh"
crun systemctl enable gigos-nvidia-load.service

# 桌面安装按钮需可执行位，KDE Folder View 才能双击启动 Calamares；skel 会复制到各用户 ~/Desktop。
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/calamares.desktop"

# 两个启动 SSH 按钮（允许密码登录、仅密钥）及其前后端脚本，供 live 调试使用。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh.sh" "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh-button.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-password.desktop" "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-keyonly.desktop"

# 关闭自动休眠与锁屏的按钮及脚本，避免装机被 15 分钟自动休眠或锁屏打断。
# skel 已默认禁用两者，此按钮供显式确认并立即生效；装好的系统由 calamares 复位回 KDE 默认。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-nosleep.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-nosleep.desktop"

# 开启 sudo 免密的按钮及脚本，前端经 pkexec 调用 root 后端写 sudoers drop-in，供 live 调试使用。
# 装好的系统由 calamares 删除 drop-in 与按钮，sudo 恢复为需要密码。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-sudo.sh" "${WORKDIR}/squashfs/usr/local/bin/gigos-sudo-button.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-sudo-nopasswd.desktop"

# ZFS 根装机处理脚本，由 calamares shellprocess@zfspre 与 @zfs 在目标 chroot 内调用。
# 这不是 live systemd 服务，故没有 systemctl enable，与 gigos-fix-crypttab.sh 相同。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-zfs-bootmenu.sh"
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-zfs-prebootloader.sh"
# LUKS 加密根装机的开机卡死修复脚本。calamares shellprocess 用 test -x 调用它，
# 缺少可执行位会静默跳过，加密安装因此不可启动。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-fix-crypttab.sh"
