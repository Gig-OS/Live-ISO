#!/bin/bash
# 桌面「关闭自动休眠和锁屏」按钮（以 live 用户跑，无需 root——powerdevil/锁屏是用户级配置）。
# 装机可能要几十分钟，机器不该 15 分钟自动休眠/锁屏中断。本按钮把当前会话的自动休眠、熄屏、
# 自动锁屏都关掉（屏幕仍可变暗），立即生效并弹框反馈。提示文案跟随会话 LANG，三语言。
# 注:live skel 已默认禁这些(powerdevilrc/kscreenlockerrc)；本按钮供显式一键确保 + 即时生效。
# 装好的系统由 calamares 清理复位，恢复 KDE 默认电源管理。
set -e
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

kwriteconfig6 --file powerdevilrc --group AC      --group SuspendAndShutdown --key AutoSuspendAction 0
kwriteconfig6 --file powerdevilrc --group Battery --group SuspendAndShutdown --key AutoSuspendAction 0
kwriteconfig6 --file powerdevilrc --group AC      --group DPMSControl --key idleTime 86400
kwriteconfig6 --file powerdevilrc --group Battery --group DPMSControl --key idleTime 86400
kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false

# 立即生效:powerdevil 监听配置文件变更会自动重读;再显式戳一下兜底。
qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement refreshStatus >/dev/null 2>&1 || true
qdbus6 org.freedesktop.ScreenSaver /ScreenSaver configure >/dev/null 2>&1 || true

case "${LANG:-}" in
  en*)
    MSG="Auto-suspend, screen-off and screen lock are now off for this session (the screen may still dim). Good for long installs.\n\nThe installed system keeps normal power settings." ;;
  zh_TW*|zh_Hant*)
    MSG="本次工作階段已關閉自動休眠、熄螢幕與鎖定（螢幕仍可能變暗）。適合長時間安裝。\n\n裝好的系統維持正常電源設定。" ;;
  *)
    MSG="本次会话已关闭自动休眠、熄屏与锁屏（屏幕仍可能变暗）。适合长时间安装。\n\n装好的系统保持正常电源设置。" ;;
esac
kdialog --title "Power" --msgbox "$MSG" 2>/dev/null || notify-send "Power" "$MSG" 2>/dev/null || true
exit 0
