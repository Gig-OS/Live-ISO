#!/bin/bash
# gigos-fix-crypttab.sh — 装机后(Calamares shellprocess,目标 chroot 内,dontChroot:false → ROOT=/)
# 修复 LUKS 加密根开机卡死(卡 3 个点)。
#
# 背景:加密根由 initramfs 解锁(kernel cmdline rd.luks.uuid + 内建 keyfile),但真实根 systemd 不知它
#   已被 initrd 挂接,死等其 .device 单元 →「A start job is running for /dev/.../<uuid> (no limit)」。
# 解法(贴合 systemd crypttab(5)):给「由 initramfs 解锁的设备」(挂载 / 或 /usr 的加密卷)的 crypttab
#   条目加 x-initrd.attach;非 root(/home /data 等,pivot 后才解、无 rd.luks.uuid)不加——加了会被
#   dracut 拽进 initramfs 早期、却无内建 keyfile,反而要密码/卡。
# root 判据:从 /etc/fstab 取挂载 / 和 /usr 的设备 /dev/mapper/luks-<UUID>,匹配 crypttab 同 UUID 的行。
#   不能按 keyfile 字段判:gig 的 Calamares fstab 模块早于 luksbootkeyfile 跑,root 的密钥字段写成 none。
# 用脚本而非内联 sed:绕开 Calamares 宏展开对 $ / $() 的处理,逻辑清晰可维护、QEMU 实测验证过。
# 一次性安装器助手,执行后自删,不进装好的系统。
set -e
CT=/etc/crypttab
FS=/etc/fstab
if [ -f "$CT" ] && [ -f "$FS" ]; then
  for mp in / /usr; do
    dev=$(awk -v m="$mp" '$1!~/^#/ && $2==m {print $1; exit}' "$FS")
    uuid=$(printf '%s' "$dev" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    [ -n "$uuid" ] && sed -i "/$uuid/{/x-initrd.attach/!s/luks[[:space:]]*$/luks,x-initrd.attach/}" "$CT"
  done
  command -v dracut >/dev/null 2>&1 && dracut --force --regenerate-all || true
fi
rm -f "$0" 2>/dev/null || true
