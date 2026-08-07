#!/bin/bash

# 把 /etc/os-release 中的几个 URL 指向 Gentoo 中文社区。
# Calamares 的 branding.desc 从 ${SUPPORT_URL} 与 ${BUG_REPORT_URL} 取值，沿用 Gentoo 官方 os-release
# 会让欢迎页的支持与报错按钮指向 gentoo.org，本 ISO 的问题被报到上游后无人受理。
#
# baselayout 把 /etc/os-release 做成指向 ../usr/lib/os-release 的软链，而 os-release 规范中 /etc 下的
# 真文件优先，故此处替换为真文件，不改动 baselayout 自带的那份以免升级冲突。
# 只改 URL，保留 NAME、PRETTY_NAME 与 VERSION。
#
# hooks 由 build.sh source 执行，此处不能用 set -u 或 exit，否则会污染或终止整次构建。

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
