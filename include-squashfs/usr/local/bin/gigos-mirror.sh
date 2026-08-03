#!/bin/sh
# 按所在地区自动选就近镜像，覆盖 GENTOO_MIRRORS 与 Portage 树的 git 同步地址。
#
# 判据优先用出口 IP 的国家码，取不到再退回系统语言。镜像快慢取决于网络距离而非界面语言，
# 在中国用英文界面的人应该拿到国内源，在海外用简体的人应该拿到海外源。
#
# 只有中国大陆用国内源。台湾与香港走当地镜像，不用大陆源。其余一律海外源，也是出厂基线，
# 所以本服务只在判定为大陆或台港时才改写。
#
# GENTOO_MIRRORS 末尾追加社区 overlay 的 distfiles 源。它只提供 gentoo-zh 里那些包的源码，
# 不能替代官方源，所以是追加。二进制包没有配，因为 binhost 的 profile 是
# default/linux/amd64/23.0/desktop，与本 ISO 的 desktop/plasma/systemd 不一致，
# portage 会静默跳过不匹配的包，配了也不会命中。
#
# 与 gigos-cpuflags 同一套机制：写入的文件都带标记行，用户删掉标记即停止自动覆盖。
# make.conf/ 与 repos.conf/ 都按字母序加载，本服务写的文件排在出厂文件之后，因而覆盖它们。
set -u

MARK='# gigos-auto-mirror'
MC=/etc/portage/make.conf/mirror
RC=/etc/portage/repos.conf/zz-gigos-mirror.conf

# 任一目标文件被用户改过就整体退出，不做半套覆盖
for f in "$MC" "$RC"; do
    if [ -e "$f" ] && ! grep -q "$MARK" "$f"; then
        exit 0
    fi
done

# 出口 IP 的国家码。3 秒超时，失败留空交给语言兜底，不阻塞开机。
CC=""
if command -v curl >/dev/null 2>&1; then
    CC=$(curl -fsS -m 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
         | sed -n 's/^loc=\([A-Z][A-Z]\)$/\1/p' | head -1)
fi

# 语言兜底。装好的系统由 Calamares 写 /etc/locale.conf，live 由 gigos-live-lang 写。
LANG_VAL=""
[ -r /etc/locale.conf ] && LANG_VAL=$(. /etc/locale.conf 2>/dev/null; printf '%s' "${LANG:-}")

case "$CC" in
    CN)       REGION=cn ;;
    TW|HK|MO) REGION=tw ;;
    "")  # 没拿到国家码，按语言猜。只有简体归大陆，其余中文变体不用大陆源。
        case "$LANG_VAL" in
            zh_TW*|zh_HK*|zh_MO*) REGION=tw ;;
            zh_CN*)               REGION=cn ;;
            *)                    REGION=global ;;
        esac
        ;;
    *)        REGION=global ;;
esac

case "$REGION" in
    cn)
        DESC="中国大陆"
        MIRRORS="https://mirrors.ustc.edu.cn/gentoo/ https://mirrors.bfsu.edu.cn/gentoo/ https://mirrors.tuna.tsinghua.edu.cn/gentoo/ https://mirrors.aliyun.com/gentoo/"
        # 社区 overlay 的源码 tarball。追加在官方源之后，只补 gentoo-zh 里那些包，不替代官方源。
        ZH_DIST="https://mirrors.cernet.edu.cn/gentoo-zh https://mirror.nju.edu.cn/gentoo-zh https://mirror.nyist.edu.cn/gentoo-zh https://distfiles.gentoozh.org"
        # 只有 gentoo 与 gentoo-zh 有国内 git 镜像。guru 在清华、中科大、北外、CERNET 上都没有，
        # gig 是社区自有仓库也无镜像，两者保持出厂的 GitHub 地址。
        GIT_GENTOO="https://mirrors.cernet.edu.cn/gentoo-portage.git"
        GIT_ZH="https://mirrors.cernet.edu.cn/gentoo-zh.git"
        ;;
    tw)
        DESC="台湾 / 香港"
        MIRRORS="http://ftp.twaren.net/Linux/Gentoo/ https://tw.mirrors.cicku.me/gentoo/ https://hk.mirrors.cicku.me/gentoo/ https://mirror.xtom.com.hk/gentoo/"
        ZH_DIST="https://distfiles.gentoozh.org"
        # 当地没有实测可用的 Portage 树 git 镜像，GitHub 可直连，保持出厂值，不用大陆源。
        GIT_GENTOO=""
        GIT_ZH=""
        ;;
    *)
        DESC="全球 / 海外"
        MIRRORS="https://distfiles.gentoo.org/ https://gentoo.osuosl.org/ https://ftp.fau.de/gentoo/"
        ZH_DIST="https://distfiles.gentoozh.org"
        GIT_GENTOO=""
        GIT_ZH=""
        ;;
esac

if [ -n "$CC" ]; then
    SRC="出口 IP 国家码 $CC"
else
    SRC="系统语言 ${LANG_VAL:-未设}"
fi

mkdir -p /etc/portage/make.conf /etc/portage/repos.conf
{
    echo "$MARK"
    echo "# 由 gigos-mirror 按${SRC}判定为${DESC}，自动选就近镜像。"
    echo "# 删除上面这行标记即停止自动覆盖，可改成自己的值(或执行 \`mirrorselect -s4 -b10 -o >> 本文件\`)。"
    printf 'GENTOO_MIRRORS="%s %s"\n' "$MIRRORS" "$ZH_DIST"
} > "$MC"

# 只有存在区域 git 镜像时才写覆盖文件；否则删掉旧的，让出厂的 GitHub 地址生效。
if [ -n "$GIT_GENTOO" ] || [ -n "$GIT_ZH" ]; then
    {
        echo "$MARK"
        echo "# 由 gigos-mirror 按${SRC}判定为${DESC}，覆盖 Portage 树与 gentoo-zh 的 git 同步地址。"
        echo "# 删除上面这行标记即停止自动覆盖。repos.conf/ 按字母序加载，本文件排在出厂文件之后。"
        [ -n "$GIT_GENTOO" ] && printf '\n[gentoo]\nsync-uri = %s\n' "$GIT_GENTOO"
        [ -n "$GIT_ZH" ] && printf '\n[gentoo-zh]\nsync-uri = %s\n' "$GIT_ZH"
    } > "$RC"
elif [ -e "$RC" ] && grep -q "$MARK" "$RC"; then
    rm -f "$RC"
fi
