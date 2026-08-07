#!/bin/bash
# 桌面 sudo 免密按钮的 root 后端，经 pkexec 调用。用法:gigos-sudo.sh on|off
# 为 live 用户开关 NOPASSWD，仅供 live 调试；装好的系统由 Calamares 删除此 drop-in，恢复为需要密码。
set -e
DROP=/etc/sudoers.d/00-gigos-nopasswd
case "${1:-}" in
  on)
    # 某些 stage3 里 /etc/sudoers.d 不存在，而 `@includedir` 对缺失目录静默跳过，
    # 结果是 sudo 不报错但 drop-in 无处可放，故先建目录。
    mkdir -p /etc/sudoers.d && chmod 0755 /etc/sudoers.d
    printf '# gigos 桌面按钮开启的 sudo 免密(live 调试用，装机后由 calamares 删除)\nlive ALL=(ALL) NOPASSWD: ALL\n' > "$DROP"
    chmod 0440 "$DROP"
    visudo -cf "$DROP" >/dev/null 2>&1 || { rm -f "$DROP"; echo "sudoers 语法校验失败，已撤销" >&2; exit 1; }
    ;;
  off)
    rm -f "$DROP"
    ;;
  *)
    echo "用法：$0 on|off" >&2; exit 2
    ;;
esac
exit 0
