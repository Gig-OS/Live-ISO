#!/bin/bash
# 桌面 SSH 按钮的前端(以 live 用户跑):pkexec 调 root 后端(会弹框要密码授权),
# 再用 kdialog 报告结果与连接信息。提示文案跟随会话 LANG,三语言(简/繁/英)。
MODE="${1:-}"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

case "${LANG:-}" in
  en*)
    T_FAIL="SSH start failed (authorization cancelled or error)."
    T_PW="SSH is running (password login allowed).\n\n  ssh live@${IP}\n\nUser live / root, password as you set it (default: live)."
    T_KEY="SSH is running (key only).\n\n  ssh -i <your key> live@${IP}\n\nPut your public key in ~live/.ssh/authorized_keys." ;;
  zh_TW*|zh_Hant*)
    T_FAIL="SSH 啟動失敗(取消授權或出錯)。"
    T_PW="SSH 已啟動（允許密碼登入）。\n\n  ssh live@${IP}\n\n使用者 live / root,密碼為你設定的密碼(預設 live)。"
    T_KEY="SSH 已啟動（僅金鑰登入）。\n\n  ssh -i <你的私鑰> live@${IP}\n\n把公鑰放進 ~live/.ssh/authorized_keys。" ;;
  *)
    T_FAIL="SSH 启动失败(取消授权或出错)。"
    T_PW="SSH 已启动（允许密码登录）。\n\n  ssh live@${IP}\n\n用户 live / root,密码为你设定的密码(默认 live)。"
    T_KEY="SSH 已启动（仅密钥登录）。\n\n  ssh -i <你的私钥> live@${IP}\n\n把公钥放进 ~live/.ssh/authorized_keys。" ;;
esac

if ! pkexec /usr/local/bin/gigos-ssh.sh "$MODE"; then
    kdialog --error "$T_FAIL" 2>/dev/null || notify-send "SSH" "$T_FAIL" 2>/dev/null || true
    exit 1
fi
case "$MODE" in
    password) MSG="$T_PW" ;;
    keyonly)  MSG="$T_KEY" ;;
    *)        MSG="SSH: ${MODE}" ;;
esac
kdialog --title "SSH（${IP}）" --msgbox "$MSG" 2>/dev/null || notify-send "SSH ${IP}" "$MSG" 2>/dev/null || true
