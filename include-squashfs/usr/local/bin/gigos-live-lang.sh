#!/bin/bash
# Live 开机语言切换:读内核 cmdline 的 gigos.lang=,在登录管理器启动【前】
# 设置系统 locale、Plasma 界面语言、环境 LANG 三处,使 grub 选的语言真正生效。
#
# 仅用于 live 环境(Calamares 装机会让用户在安装器里重新选语言;装好的系统由
# Calamares 写正式 locale,本服务对装好的系统无影响——它只读 live 的内核 cmdline)。
#
# 支持的 gigos.lang 值:zh_CN(默认) / zh_TW / en_US
# KDE 的系统 locale 与 Plasma UI 语言是两套:plasma-localerc 的 [Translations]LANGUAGE 管
# 界面语言、[Formats]LANG 管区域格式【且被 Plasma 会话导出为 LANG】——两者都要按所选语言设,
# 否则会「界面英文但会话 LANG=zh_CN → Firefox 等非 KDE 程序仍跟着变中文」(实机踩过)。

set -u

# 解析内核 cmdline 的 gigos.lang=,缺省为简体中文
LANG_CHOICE="zh_CN"
for tok in $(cat /proc/cmdline); do
    case "$tok" in
        gigos.lang=*) LANG_CHOICE="${tok#gigos.lang=}" ;;
    esac
done

# 白名单校验,非法值回落简体,避免设出无效 locale
case "$LANG_CHOICE" in
    zh_CN|zh_TW|en_US) : ;;
    *) LANG_CHOICE="zh_CN" ;;
esac

FULL_LOCALE="${LANG_CHOICE}.UTF-8"

# ① 系统 locale(/etc/locale.conf;live rootfs 此时已是可写的 overlay)
echo "LANG=${FULL_LOCALE}" > /etc/locale.conf

# ② Plasma 界面语言:写 live 用户的 plasma-localerc([Translations] LANGUAGE=)
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

# ③ 环境 LANG(给 SDDM 会话与非 KDE 应用):运行时写 96-gigos-runtime-lang.conf。
#    这是【运行时】文件、不进 squashfs,所以装好的系统不会被它强制 LANG(由 Calamares 写的
#    /etc/locale.conf 按用户所选 locale 决定)。XMODIFIERS 在 90-fcitx5.conf,本脚本不碰。
mkdir -p /etc/environment.d
echo "LANG=${FULL_LOCALE}" > /etc/environment.d/96-gigos-runtime-lang.conf

echo "[gigos-live-lang] 已设语言:${LANG_CHOICE}（系统 locale + Plasma 界面 + LANG）"
