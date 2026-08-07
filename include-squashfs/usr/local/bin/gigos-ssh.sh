#!/bin/bash
# 桌面 SSH 按钮的 root 后端，经 pkexec 调用。用法:gigos-ssh.sh password|keyonly
# live 默认不启用 sshd，且 /etc/ssh/sshd_config.d/9999999gentoo.conf 设了 PasswordAuthentication no。
# 因为 sshd 取首个匹配的配置项，所以密码登录用一个排在它之前的 drop-in 覆盖。
set -e
DROP=/etc/ssh/sshd_config.d/00-gigos-passwordlogin.conf
case "${1:-}" in
  password)
    printf '# gigos 桌面按钮开启的密码登录(live 调试用；文件名 00 排在 9999999gentoo*.conf 之前,sshd 首个匹配生效)\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPermitRootLogin yes\n' > "$DROP"
    ;;
  keyonly)
    rm -f "$DROP"
    ;;
  *)
    echo "用法：$0 password|keyonly" >&2; exit 2
    ;;
esac
ssh-keygen -A >/dev/null 2>&1 || true
systemctl enable sshd >/dev/null 2>&1 || true
# 必须让运行中的 sshd 重载才会应用上面新写或删除的 drop-in。不能用 `enable --now`:sshd 已运行时
# 它直接返回成功而不重载，`|| restart` 也就不触发，改动不生效。reload-or-restart 在 sshd 运行时
# 发 SIGHUP 重读配置，未运行则启动。
systemctl reload-or-restart sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl start sshd
exit 0
