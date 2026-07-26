#!/bin/bash
# 桌面「开启 sudo 免密」按钮的 root 后端（经 pkexec 调用）。用法: gigos-sudo.sh on|off
# 给 live 用户开/关 sudo 免密码(NOPASSWD)。仅 live 调试方便;装好的系统由 calamares 删此 drop-in
# (恢复 sudo 需密码,安全)。
set -e
DROP=/etc/sudoers.d/00-gigos-nopasswd
case "${1:-}" in
  on)
    # /etc/sudoers.d 在某些 stage3 里默认不存在(@includedir 对缺失目录静默跳过,故 sudo 不报错但
    # drop-in 无处可放=按钮没用)。先建好目录再写。/etc/sudoers 已含 @includedir /etc/sudoers.d。
    mkdir -p /etc/sudoers.d && chmod 0755 /etc/sudoers.d
    printf '# gigos 桌面按钮开启的 sudo 免密(live 调试用;装机后由 calamares 删除)\nlive ALL=(ALL) NOPASSWD: ALL\n' > "$DROP"
    chmod 0440 "$DROP"
    visudo -cf "$DROP" >/dev/null 2>&1 || { rm -f "$DROP"; echo "sudoers 语法校验失败,已撤销" >&2; exit 1; }
    ;;
  off)
    rm -f "$DROP"
    ;;
  *)
    echo "用法: $0 on|off" >&2; exit 2
    ;;
esac
exit 0
