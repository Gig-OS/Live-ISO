#!/bin/bash
# 装机后由 Calamares shellprocess 在目标 chroot 内执行（dontChroot:false → ROOT=/），修复 LUKS 加密根
# 开机卡在 `A start job is running for /dev/.../<uuid>`:加密根已由 initramfs 解锁（kernel cmdline
# `rd.luks.uuid` 加内建 keyfile），但真实根的 systemd 不知情，死等对应的 .device 单元。
# 解法是给挂载 / 或 /usr 的加密卷在 crypttab 条目加 `x-initrd.attach`。非 root 卷（/home、/data 等在
# pivot 之后才解锁、无 `rd.luks.uuid`）不能加，加了会被 dracut 拽进 initramfs 早期却无内建 keyfile，
# 反而要求输入密码。
# root 判据取自 /etc/fstab 中挂载 / 与 /usr 的 `/dev/mapper/luks-<UUID>`，匹配 crypttab 中同 UUID 的行。
# 不能按 keyfile 字段判断，因为 Calamares 的 fstab 模块早于 luksbootkeyfile 执行，root 的密钥字段是 none。
# 用脚本而非内联 sed，绕开 Calamares 宏展开对 `$` 与 `$()` 的处理。
# 一次性安装器助手，执行后自删。
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
