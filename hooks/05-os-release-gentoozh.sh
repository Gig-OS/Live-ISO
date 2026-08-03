#!/bin/bash

# 把 /etc/os-release 里的几个 URL 指向 Gentoo 中文社区。
#
# 为什么必须改:Calamares 的 branding.desc 用 ${SUPPORT_URL} / ${BUG_REPORT_URL} 取值，而 live 用的是
# Gentoo 官方 os-release,于是欢迎页的支持信息按钮指向 gentoo.org/support、已知问题按钮指向 bugs.gentoo.org
# 本 ISO 的问题会被报到上游，我们收不到，上游也无法受理。
#
# baselayout 把 /etc/os-release 做成指向 ../usr/lib/os-release 的软链；按 os-release 规范，/etc 下的
# 真文件优先于 /usr/lib 下的，所以这里把软链换成真文件(不动 baselayout 自己那份，升级不冲突)。
# 只改 URL,不动 NAME/PRETTY_NAME/VERSION,系统仍如实自称 Gentoo,不做改名式换皮。
#
# 注意:hooks 是被 source 的，这里不能用 set -u / exit(会污染或直接终止整个构建)。

_osrel_src="${WORKDIR}/squashfs/usr/lib/os-release"
_osrel_dst="${WORKDIR}/squashfs/etc/os-release"

if [ -f "${_osrel_src}" ]; then
    _osrel_tmp="$(mktemp)"
    grep -vE '^(HOME_URL|SUPPORT_URL|BUG_REPORT_URL|DOCUMENTATION_URL)=' "${_osrel_src}" > "${_osrel_tmp}"
    cat >> "${_osrel_tmp}" <<'OSRELEOF'
HOME_URL='https://gentoozh.org/'
SUPPORT_URL='https://forum.gentoozh.org/'
BUG_REPORT_URL='https://github.com/Gig-OS/Live-ISO/issues'
DOCUMENTATION_URL='https://gentoozh.org/'
OSRELEOF
    rm -f "${_osrel_dst}"
    install -m644 "${_osrel_tmp}" "${_osrel_dst}"
    rm -f "${_osrel_tmp}"
    echo "[05-os-release] os-release 的 URL 已指向社区(支持=论坛、报错=Live-ISO issues)"
else
    echo "[05-os-release] 警告：找不到 ${_osrel_src},保持原样"
fi

unset _osrel_src _osrel_dst _osrel_tmp
