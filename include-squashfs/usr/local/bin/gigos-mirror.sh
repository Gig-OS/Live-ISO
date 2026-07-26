#!/bin/sh
# 按系统语言(/etc/locale.conf 的 LANG)自动选 GENTOO_MIRRORS 区域镜像,写入 make.conf。
# 我们的 ISO 支持简 / 繁 / 英三语,用户分布在中国大陆 / 台湾·香港 / 海外:写死单一中国镜像
# 对繁体、英文用户并不友好。本服务在 live 与装好的系统每次启动按所选语言挑就近镜像。
# 与 gigos-cpuflags 同一套机制:出厂是带标记的安全基线,本服务按语言重算覆盖;
# 一旦用户删掉标记行(表示已自定义,或自己跑了 mirrorselect),即停止覆盖,尊重用户。
#
# 注:make.conf/ 下文件按字母序加载,'mirror' 在 'common' 之后 → 这里的 GENTOO_MIRRORS
# 覆盖 common 的兜底值。镜像只决定从哪拉 distfiles/源码包,与系统语言/区域无强绑定,
# 用语言做就近猜测、并允许用户一键改,是省事又不锁死的折中。
set -u
F=/etc/portage/make.conf/mirror
MARK='# gigos-auto-mirror'

# 文件存在且【没有】自动标记 = 用户已手改 → 不动它
if [ -e "$F" ] && ! grep -q "$MARK" "$F"; then
    exit 0
fi

# 读系统语言(装好的系统由 Calamares 写 /etc/locale.conf;live 由 gigos-live-lang 写)
LANG_VAL=""
[ -r /etc/locale.conf ] && LANG_VAL=$(. /etc/locale.conf 2>/dev/null; printf '%s' "${LANG:-}")

case "$LANG_VAL" in
    zh_TW*|zh_HK*|zh_MO*)
        REGION="台湾 / 香港"
        MIRRORS="http://ftp.twaren.net/Linux/Gentoo/ https://tw.mirrors.cicku.me/gentoo/ https://hk.mirrors.cicku.me/gentoo/ https://mirror.xtom.com.hk/gentoo/"
        ;;
    en*|C|C.*|POSIX|"")
        REGION="全球 / 海外"
        MIRRORS="https://distfiles.gentoo.org/ https://gentoo.osuosl.org/ https://ftp.fau.de/gentoo/"
        ;;
    *)  # zh_CN 及其他默认 → 中国大陆
        REGION="中国大陆"
        MIRRORS="https://mirrors.aliyun.com/gentoo/ https://mirrors.tuna.tsinghua.edu.cn/gentoo/ https://mirrors.ustc.edu.cn/gentoo/ https://mirrors.bfsu.edu.cn/gentoo/"
        ;;
esac

{
    echo "$MARK"
    echo "# 由 gigos-mirror 按系统语言(${LANG_VAL:-未设} → ${REGION})自动选就近镜像。"
    echo "# 删除上面这行标记即停止自动覆盖,可改成自己的值(或跑 \`mirrorselect -s4 -b10 -o >> 本文件\`)。"
    printf 'GENTOO_MIRRORS="%s"\n' "$MIRRORS"
} > "$F"
