#!/bin/bash
# Live 开机语言切换：读内核 cmdline 的 `gigos.lang=`，在登录管理器启动前设置系统 locale、
# Plasma 界面语言与环境 LANG,使 GRUB 所选语言生效。取值为 zh_CN（默认）、zh_TW、en_US。
# 仅用于 live 环境；装好的系统由 Calamares 写正式 locale，本服务只读 live 的内核 cmdline。
# KDE 的系统 locale 与 Plasma 界面语言是两套配置:plasma-localerc 的 `[Translations]LANGUAGE`
# 管界面语言，`[Formats]LANG` 管区域格式并被 Plasma 会话导出为 LANG,两者都要按所选语言设置，
# 否则界面为英文而会话仍是 `LANG=zh_CN`，Firefox 等非 KDE 程序照旧显示中文。

set -u

LANG_CHOICE="zh_CN"
for tok in $(cat /proc/cmdline); do
    case "$tok" in
        gigos.lang=*) LANG_CHOICE="${tok#gigos.lang=}" ;;
    esac
done

case "$LANG_CHOICE" in
    zh_CN|zh_TW|en_US) : ;;
    *) LANG_CHOICE="zh_CN" ;;
esac

FULL_LOCALE="${LANG_CHOICE}.UTF-8"

# 此时 live rootfs 已是可写的 overlay
echo "LANG=${FULL_LOCALE}" > /etc/locale.conf

LIVE_HOME="/home/live"
if [ -d "$LIVE_HOME" ]; then
    install -d -o live -g live "$LIVE_HOME/.config"
    cat > "$LIVE_HOME/.config/plasma-localerc" <<RC
[Formats]
LANG=${FULL_LOCALE}

[Translations]
LANGUAGE=${LANG_CHOICE}
RC
    chown live:live "$LIVE_HOME/.config/plasma-localerc"
fi

# 给 SDDM 会话与非 KDE 应用的环境 LANG。运行时生成、不进 squashfs，因此装好的系统不受影响。
mkdir -p /etc/environment.d
echo "LANG=${FULL_LOCALE}" > /etc/environment.d/96-gigos-runtime-lang.conf

echo "[gigos-live-lang] 已设语言：${LANG_CHOICE}（系统 locale + Plasma 界面 + LANG）"
