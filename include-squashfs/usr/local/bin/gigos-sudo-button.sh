#!/bin/bash
# 桌面「开启 sudo 免密」按钮前端(以 live 用户跑):pkexec 调 root 后端写 sudoers drop-in(会弹框授权一次),
# 再用 kdialog 反馈。提示文案跟随会话 LANG,三语言(简/繁/英)。
case "${LANG:-}" in
  en*)
    T_FAIL="Failed to enable passwordless sudo (authorization cancelled or error)."
    T_OK="Passwordless sudo is on for this session — 'sudo' won't ask for a password.\n\nLive / debugging only; the installed system still requires a password." ;;
  zh_TW*|zh_Hant*)
    T_FAIL="開啟 sudo 免密失敗（取消授權或出錯）。"
    T_OK="本次工作階段已開啟 sudo 免密——「sudo」不再要求輸入密碼。\n\n僅供 live／偵錯;裝好的系統仍需密碼。" ;;
  *)
    T_FAIL="开启 sudo 免密失败（取消授权或出错）。"
    T_OK="本次会话已开启 sudo 免密——「sudo」不再要求输入密码。\n\n仅供 live／调试;装好的系统仍需密码。" ;;
esac

if ! pkexec /usr/local/bin/gigos-sudo.sh on; then
    kdialog --error "$T_FAIL" 2>/dev/null || notify-send "sudo" "$T_FAIL" 2>/dev/null || true
    exit 1
fi
kdialog --title "sudo" --msgbox "$T_OK" 2>/dev/null || notify-send "sudo" "$T_OK" 2>/dev/null || true
exit 0
