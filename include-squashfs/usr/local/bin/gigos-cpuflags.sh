#!/bin/sh
# 按本机 CPU 生成 CPU_FLAGS_X86 与 MAKEOPTS 写入 make.conf。出厂值是带标记的安全基线
# （`x86-64-v3` 与 `-j4`），live 与装好的系统每次启动都按真实 CPU 重算覆盖；用户删掉标记行
# 即视为已自定义，本脚本不再覆盖。
# MAKEOPTS 必须由脚本展开成字面量 `-jN`,因为 portage 的 make.conf 解析器不支持命令替换，
# 写入 `$(nproc)` 会让每次 emerge 报 `bad substitution` 且 MAKEOPTS 失效。
# 文件名 `cpuflags` 按字母序在 `common` 之后加载，因此这里的 MAKEOPTS 覆盖 `common` 的兜底值。
set -u
F=/etc/portage/make.conf/cpuflags
MARK='# gigos-auto-cpuflags'

if [ -e "$F" ] && ! grep -q "$MARK" "$F"; then
    exit 0
fi

command -v cpuid2cpuflags >/dev/null 2>&1 || exit 0
FLAGS=$(cpuid2cpuflags 2>/dev/null | sed 's/^CPU_FLAGS_X86: *//')
[ -n "$FLAGS" ] || exit 0

CORES=$(nproc 2>/dev/null || echo 4)
# 并行度按内存封顶：`rust`、`llvm`、`chromium`、`qtwebengine` 等大包每个编译进程约占 1-2G，
# 只按核数设 `-j` 会在高核低内存机上 OOM，而 `-l` 按 CPU 负载限流，挡不住内存超订。
# 并行度取核数与内存 GB 数一半中的较小值且至少为 1，无法取得内存则退回核数。
# `-l` 仍用核数，负载低时用满 CPU。
MEM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_GB=$(( (MEM_KB + 524288) / 1048576 ))   # 四舍五入到 GB:MemTotal 略低于物理内存
CAP=$(( MEM_GB / 2 )); [ "$CAP" -lt 1 ] && CAP=1
if [ "$MEM_GB" -gt 0 ] && [ "$CORES" -gt "$CAP" ]; then N=$CAP; else N=$CORES; fi
{
    echo "$MARK"
    echo "# 由 gigos-cpuflags 按本机 CPU 自动生成(CPU_FLAGS_X86 + MAKEOPTS);删除上面这行标记即停止自动覆盖，可改成自己的值。"
    printf 'CPU_FLAGS_X86="%s"\n' "$FLAGS"
    printf 'MAKEOPTS="-j%s -l%s"\n' "$N" "$CORES"
} > "$F"
