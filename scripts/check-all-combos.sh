#!/bin/sh
#
# 把四种勾选组合各验一遍（只到配置与断言，不编译）。
#
# ===========================================================================
# 这个脚本存在的意义
# ===========================================================================
#
# 全量编译一次要两三个小时，没人会在每次改动时都跑。但「某个组合悄悄编错了
# 包」这类问题，其实在 .config 阶段就能发现 —— 只要断言写得够严。
#
# 这个脚本跑完约十到十五分钟（大头是 feeds install，只做一次），
# 适合挂在 push / PR 上做回归。真正的固件构建仍然是 build.sh 的活。
#
# 用法：
#   ./scripts/check-all-combos.sh          # 四种组合全验
#   ./scripts/check-all-combos.sh --fast   # 跳过 feeds update（feeds 已就位时用）
#
set -eu

# 本脚本是被直接调用的（不经过 build.sh），所以 PROJECT_ROOT 要自己算。
# 名字仍然避开 TOPDIR —— 那是 OpenWrt 的 scripts/feeds 会 chdir 过去的环境
# 变量，详情见 build.sh 顶部与 docs/BUILD-NOTES.md 4.1。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

. "$PROJECT_ROOT/scripts/lib.sh"

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

# 先做一次完整准备，把源码与 feed 都装好；后面三个组合复用它们。
# ⚠️ SKIP_BUILD=1 是这个脚本的关键：它只做「拼配置 + 断言」，
#    绝不触发下载与编译。整轮下来十几分钟，而不是十几个小时。
export SKIP_BUILD=1

if [ "$FAST" = "1" ]; then
	say "第 1/4 步：准备（--fast：跳过 feeds update，复用已有 feeds）"
	SKIP_FEEDS_UPDATE=1
else
	say "第 1/4 步：完整准备（取源码 + feeds + 第一个组合）"
	SKIP_FEEDS_UPDATE=0
fi
export SKIP_FEEDS_UPDATE

WITH_FANCHMWRT=1 WITH_ISTOREOS=1 ENABLE_DOCKER=1 \
LAN_IP=192.168.100.1 ROOTFS_PARTSIZE=2048 \
	sh "$PROJECT_ROOT/build.sh" || die "组合 ①（全都要）失败"

FAILED=""

# run_combo <名称> <fanchmwrt> <istoreos> <docker>
#
# 只跑 03（铺特性层）+ 04（拼配置 + 断言）—— 源码与 feed 已经就位，
# 重跑 01/02 纯属浪费时间。
run_combo() {
	_name="$1"; _fw="$2"; _is="$3"; _dk="$4"
	printf '\n%s\n' "────────────────────────────────────────────────────────"
	say "$_name"
	if ! WITH_FANCHMWRT=$_fw WITH_ISTOREOS=$_is ENABLE_DOCKER=$_dk \
	     LAN_IP=192.168.100.1 ROOTFS_PARTSIZE=2048 \
	     SKIP_FEEDS_UPDATE=1 sh "$PROJECT_ROOT/build.sh"; then
		FAILED="$FAILED
     - $_name"
	fi
}

run_combo "组合 ②：只要 FanchmWrt（无 iStoreOS、无 Docker）" 1 0 0
run_combo "组合 ③：只要 iStoreOS（无 FanchmWrt、有 Docker）" 0 1 1
run_combo "组合 ④：都不要（纯底座）" 0 0 0

printf '\n%s\n' "════════════════════════════════════════════════════════"
if [ -n "$FAILED" ]; then
	die "以下组合未通过：$FAILED"
fi
say "四种组合全部通过"
printf '    ① FanchmWrt + iStoreOS + Docker\n'
printf '    ② 只要 FanchmWrt\n'
printf '    ③ 只要 iStoreOS\n'
printf '    ④ 纯底座\n'
