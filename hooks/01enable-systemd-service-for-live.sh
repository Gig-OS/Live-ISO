#!/bin/bash

# NetworkManager
crun systemctl enable NetworkManager
# 屏蔽 initramfs 专用的 NetworkManager-initrd.service：它与 NetworkManager.service 都声明
# BusName=org.freedesktop.NetworkManager。dmsquash-live 经 initrd→realroot 切换后两者会同时
# 被加载，systemd 报 "Two services allocated for the same bus name, refusing operation" →
# NetworkManager.service 开机加载失败、网络不自起、要手动 systemctl restart 才行。
# 本地介质启动的 live/装机系统不需要 initrd 内联网络，屏蔽它即可根除冲突。
# （另见 buildbootfiles 的 dracut --omit network-manager：从源头不把 NM 放进 initramfs。）
crun systemctl mask NetworkManager-initrd.service

# Sddm
crun systemctl enable sddm

# PipeWire 音频栈(per-user,用 --global 给所有用户建 user-unit 软链)。
# 默认未使能时 live 桌面进去就是「声卡服务连接丧失」/无声;wireplumber 是会话管理器,
# pipewire-pulse 提供 PulseAudio 兼容(KDE 音量控件走它)。三者必须一起 enable。
# 注:装好的系统同样需要声音 → 故意【不】放进 calamares 清理(它只删 live 专属残留)。
crun systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# Live 开机语言切换(读 gigos.lang= 内核参数,在 sddm 前设 locale/Plasma 语言)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-live-lang.sh"
crun systemctl enable gigos-live-lang.service

# CPU_FLAGS_X86 按本机 CPU 自动生成(live 与装好的系统每次启动按真机 CPU 覆盖 make.conf/cpuflags)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-cpuflags.sh"
crun systemctl enable gigos-cpuflags.service

# GENTOO_MIRRORS 按系统语言自动选就近镜像(简→大陆 / 繁→台港 / 英→全球;live 与装好的系统通用,
# 与 gigos-cpuflags 同套机制:出厂带标记基线,开机按语言覆盖 make.conf/mirror,用户删标记即停)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-mirror.sh"
crun systemctl enable gigos-mirror.service

# nvidia 常规加载(闭源 nvidia 启动项传 gigos.gpu=nvidia:开机后 modprobe nvidia 四件套 + 建节点,
# 非 early KMS;由服务的 ConditionKernelCommandLine 守卫,开源/AMD/Intel 项不命中)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-nvidia-load.sh"
crun systemctl enable gigos-nvidia-load.service

# 桌面「安装系统」按钮设可执行(KDE Folder View 双击直接起 Calamares;skel→各用户 ~/Desktop)
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/calamares.desktop"

# 桌面「启动 SSH」两个按钮(允许密码登录 / 仅密钥)+ 其前后端脚本设可执行(live 调试用)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh.sh" "${WORKDIR}/squashfs/usr/local/bin/gigos-ssh-button.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-password.desktop" "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-ssh-keyonly.desktop"

# 桌面「关闭自动休眠和锁屏」按钮 + 脚本设可执行(装机不被 15min 自动休眠/锁屏打断;
# skel 已默认禁休眠/锁屏,本按钮供显式一键确保+即时生效;装好的系统由 calamares 复位回 KDE 默认)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-nosleep.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-nosleep.desktop"

# 桌面「开启 sudo 免密」按钮(前端 pkexec 调 root 后端写 sudoers drop-in)+ 脚本设可执行(live 调试用;
# 装好的系统由 calamares 删 drop-in/按钮,sudo 恢复需密码)
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-sudo.sh" "${WORKDIR}/squashfs/usr/local/bin/gigos-sudo-button.sh"
chmod 0755 "${WORKDIR}/squashfs/etc/skel/Desktop/gigos-sudo-nopasswd.desktop"

# ZFS 根装机处理脚本(由 calamares shellprocess@zfspre / @zfs 在目标 chroot 内调用)设可执行。
# 注:这【不】是 live systemd 服务(无 systemctl enable),仅装机时被 Calamares 调用,同 gigos-fix-crypttab.sh。
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-zfs-bootmenu.sh"
chmod +x "${WORKDIR}/squashfs/usr/local/bin/gigos-zfs-prebootloader.sh"
