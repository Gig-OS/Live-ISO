#!/bin/bash
# 桌面「启动 SSH」按钮的 root 后端（经 pkexec 调用）。用法: gigos-ssh.sh password|keyonly
# 背景:live 默认不开 sshd;且 /etc/ssh/sshd_config.d/9999999gentoo.conf 设 PasswordAuthentication no
# （仅密钥）。本脚本按需开启 sshd,密码登录用一个排在它【之前】的 drop-in 覆盖(sshd 首个匹配生效)。
set -e
DROP=/etc/ssh/sshd_config.d/00-gigos-passwordlogin.conf
case "${1:-}" in
  password)
    printf '# gigos 桌面按钮开启的密码登录(live 调试用;文件名 00 排在 9999999gentoo*.conf 之前,sshd 首个匹配生效)\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPermitRootLogin yes\n' > "$DROP"
    ;;
  keyonly)
    rm -f "$DROP"
    ;;
  *)
    echo "用法: $0 password|keyonly" >&2; exit 2
    ;;
esac
ssh-keygen -A >/dev/null 2>&1 || true          # 首次无主机密钥则生成
systemctl enable sshd >/dev/null 2>&1 || true  # 开机自启(live 无所谓;保留无害)
# 关键:必须让运行中的 sshd【重载】才会应用上面新写/删的 drop-in。原先用 `enable --now`,
# sshd 已在跑时它直接返回成功、根本不重载(`|| restart` 也就不触发)→ 改动不生效(root 登不上、
# 改 keyonly 也不收回密码登录)。reload-or-restart:运行则 SIGHUP 重读配置(对新连接生效),
# 未运行则启动;再退化到 restart/start 兜底。
systemctl reload-or-restart sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || systemctl start sshd
exit 0
