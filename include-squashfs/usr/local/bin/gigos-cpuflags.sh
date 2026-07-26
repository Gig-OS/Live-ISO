#!/bin/sh
# 按本机 CPU 自适应生成 CPU_FLAGS_X86 + MAKEOPTS 并行度,写入 make.conf。
# 出厂是带标记的安全基线(x86-64-v3 / -j4);本服务在 live 与装好系统的每次启动
# 按真实 CPU 重算覆盖。一旦用户删掉标记行(表示已自定义),即停止覆盖,尊重用户。
# 注:MAKEOPTS 必须在【运行时】用脚本展开 $(nproc) 写成字面量 -jN —— portage 的
# make.conf 解析器不支持 $(命令替换),直接把 $(nproc) 写进 make.conf 会每次 emerge
# 报 "bad substitution" 且 MAKEOPTS 失效(这是本服务接管 MAKEOPTS 的原因)。
# 文件名 'cpuflags' 字母序在 'common' 之后加载,故这里的 MAKEOPTS 覆盖 common 的兜底值。
set -u
F=/etc/portage/make.conf/cpuflags
MARK='# gigos-auto-cpuflags'

# 文件存在且【没有】自动标记 = 用户已手改 → 不动它
if [ -e "$F" ] && ! grep -q "$MARK" "$F"; then
    exit 0
fi

command -v cpuid2cpuflags >/dev/null 2>&1 || exit 0
FLAGS=$(cpuid2cpuflags 2>/dev/null | sed 's/^CPU_FLAGS_X86: *//')
[ -n "$FLAGS" ] || exit 0

N=$(nproc 2>/dev/null || echo 4)
{
    echo "$MARK"
    echo "# 由 gigos-cpuflags 按本机 CPU 自动生成(CPU_FLAGS_X86 + MAKEOPTS);删除上面这行标记即停止自动覆盖,可改成自己的值。"
    printf 'CPU_FLAGS_X86="%s"\n' "$FLAGS"
    printf 'MAKEOPTS="-j%s -l%s"\n' "$N" "$N"
} > "$F"
