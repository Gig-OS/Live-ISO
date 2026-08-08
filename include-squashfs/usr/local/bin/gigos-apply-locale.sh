#!/bin/bash
# Plasma 的界面语言读 plasma-localerc，不读 localecfg 写的 /etc/locale.conf，缺了桌面语言
# 会与安装时所选语言不一致。由 Calamares 的 shellprocess 执行，必须排在 localecfg 之后。

set -u

CONF=/etc/locale.conf
[ -r "${CONF}" ] || { echo "[gigos-locale] ${CONF} 不可读，跳过"; exit 0; }

FULL=$(sed -n 's/^[[:space:]]*LANG=//p' "${CONF}" | tr -d '"' | head -n1)
[ -n "${FULL}" ] || { echo "[gigos-locale] ${CONF} 里没有 LANG，跳过"; exit 0; }

# LANGUAGE 不带编码后缀，locale.conf 的 zh_CN.UTF-8 与 eselect 写的 zh_CN.utf8 都要去掉
mkdir -p /etc/xdg
cat > /etc/xdg/plasma-localerc <<RC
[Formats]
LANG=${FULL}

[Translations]
LANGUAGE=${FULL%%.*}
RC

echo "[gigos-locale] Plasma 界面语言与区域格式已设为 ${FULL}"
