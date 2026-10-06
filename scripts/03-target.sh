#!/bin/sh
#
# 第 3b 步：铺入**目标平台**专属的东西。
#
# ---------------------------------------------------------------------------
# 分工
# ---------------------------------------------------------------------------
#   03-overlay.sh   管「特性」——FanchmWrt / iStoreOS / Docker，与目标无关
#   03-target.sh    管「目标」——x86_64 / rockchip-armv8，与特性正交
#
# 之所以要分开：x86_64 与 rockchip 的差别**不在包选集**，而在设备层 ——
# 设备树、U-Boot 板级支持，以及 target/linux 下那几个按板子分支的文件。
# 这些东西既不属于任何特性层，也没法靠 .config 里选包来表达。
#
# 于是「四个特性复选框」那套正交性不会被破坏：目标只决定设备层，
# 特性层照旧随勾选走。任意目标 × 任意特性组合都成立。
#
# ---------------------------------------------------------------------------
# 为什么用「结构化插入」而不是补丁
# ---------------------------------------------------------------------------
# 要改的这四个文件 —— board.d/01_leds、board.d/02_network、image/armv8.mk、
# uboot-rockchip/Makefile —— 在两棵上游树里的内容**不一样**。
#
# 举一个已经核对过的例子：ImmortalWrt 的 armv8.mk 里**没有** hinlink_h28k，
# 而 fanchmwrt 那棵树里有。同一个设备定义，在两边要插的位置不同、上下文也不同。
# 而且上游每加一块板子，这几个文件都会变。
#
# 按上下文匹配的补丁会在上游改动的那天失效，而失效现场是「编译到一半 patch
# 报错」，看起来像补丁写错了 —— 排查成本远高于收益。本仓库在 v2ray-geodata
# 上已经吃过一次同样的亏，教训写在 03-overlay.sh 里：
#     「一个会在上游改文件时失效的补丁，等于给未来埋一颗定时炸弹。」
#
# 所以改成**按结构锚点插入**：只认 esac、case 的默认分支、设备清单的边界
# 这类结构性特征，不认任何具体设备的内容。上游加多少板子都不影响。
#
# ---------------------------------------------------------------------------
# 幂等与失败语义
# ---------------------------------------------------------------------------
#   * 插入前查标记 —— 已插过就跳过，重复跑 build.sh 不会插第二遍；
#   * 插入后立刻复查 —— 标记没进去就当场 die；
#   * 锚点没匹配上 —— 当场 die，而不是静默跳过。
#
# 最后一条是关键：静默跳过的后果是「编译成功、固件里却没有那个设备分支」，
# 比构建失败糟糕得多。宁可现在停下来让人看一眼。
#
set -eu
# 自己推导项目根，不依赖调用方 export。
#
# 这些脚本都能单独运行（CI 就是把 09-verify.sh 拆成一个独立 step 调的），
# 而 build.sh 里那句 export 只在经过它时才有效。漏了这两行的后果是
#     ./scripts/03-target.sh: PROJECT_ROOT: parameter not set
# —— 编译全过、这一步直接挂掉。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

. "$PROJECT_ROOT/scripts/lib.sh"

SRC="$PROJECT_ROOT/openwrt"
[ -d "$SRC" ] || die "没找到 $SRC，请先跑 scripts/01-fetch.sh"

TARGET="${TARGET:-x86_64}"

# 本步铺进去的东西，全部带这个名字的标记；反过来也靠它精确删除。
MARK_BEGIN="# >>> immortalwrt-fusion/target: rockchip-ht2 begin"
MARK_END="# <<< immortalwrt-fusion/target: rockchip-ht2 end"

ROCKCHIP_OVERLAY="$PROJECT_ROOT/overlay/target/rockchip-armv8"

# ---------------------------------------------------------------------------
# 插入 helper
#
# 三个坑，都踩过，写在这里免得再踩：
#
# 1. **标记必须带 tag。**  一开始所有插入共用一对全局标记，结果同一个文件里
#    插第二块时，`has_block` 看到第一块的标记就以为「已经插过了」，直接跳过 ——
#    02_network 要插两处（网口一处、MAC 一处），第二处就静默丢了。
#    现在每个插入点有自己的 tag，互不干扰。
#
# 2. **不要用 awk 的 -v 传锚点。**  GNU awk 会对 -v 的值做转义处理，
#    锚点里的 `\\$`（想匹配行尾的反斜杠）会被吃成 `\$`，正则里就变成
#    「匹配一个美元符号」—— 于是永远匹配不上，而 grep 那边因为用的是另一套
#    转义规则**能**匹配上。表现是「grep 说锚点在，awk 却插不进去」。
#    改用 ENVIRON[] 传：环境变量不经转义处理，原样到达。
#
# 3. **ENVIRON 的赋值必须写在 awk 命令前面。**
#    `awk 'prog' VAR=val file` 里的 VAR 是 awk 的普通变量，ENVIRON[] 里没有它。
#    于是 ENVIRON["X"] 取到空串、index($0,"") 对每一行都成立 ——
#    表现为「插进去了但复查说没有成对标记」，或者更糟：静默插错位置。
#
# 锚点一律用「整行相等」，不用正则：要锚的行里有反斜杠（make 续行）、
# 有制表符、有 `*`，写成正则是自找麻烦。
# ---------------------------------------------------------------------------

MARK_PREFIX="# >>> immortalwrt-fusion/target begin:"
MARK_SUFFIX="# <<< immortalwrt-fusion/target end:"

mark_begin() { printf '%s %s' "$MARK_PREFIX" "$1"; }
mark_end()   { printf '%s %s' "$MARK_SUFFIX" "$1"; }

# has_block <file> <tag> —— 这个 tag 的一对标记是否都齐
has_block() {
	grep -qF "$(mark_begin "$2")" "$1" && grep -qF "$(mark_end "$2")" "$1"
}

# strip_marked <file>
#
# 删掉本脚本插过的**所有**块（不论 tag），用于换目标 / 取消目标时的干净回退。
strip_marked() {
	_file="$1"
	grep -qF "$MARK_PREFIX" "$_file" || return 0
	awk -v p="$MARK_PREFIX" -v q="$MARK_SUFFIX" '
		index($0, p) { skip = 1; next }
		index($0, q) { skip = 0; next }
		!skip        { print }
	' "$_file" > "$_file.tmp.$$"
	mv "$_file.tmp.$$" "$_file"
	say "  已回退：${_file#"$SRC/"}"
}

# _awked_insert <file> <整行锚点> <片段> <first|last> <tag> <描述>
_awked_insert() {
	_file="$1"
	_anchor="$2"
	_snippet="$3"
	_mode="$4"
	_tag="$5"
	_what="$6"

	[ -f "$_snippet" ] || die "片段文件不存在：$_snippet"

	# 赋值写在 awk 前面（见上面第 3 条）。
	_hits=$(AF_ANCHOR="$_anchor" awk '
		index($0, ENVIRON["AF_ANCHOR"]) == 1 && length($0) == length(ENVIRON["AF_ANCHOR"])
	' "$_file" | wc -l)
	[ "$_hits" -gt 0 ] || die "锚点没匹配上，拒绝静默跳过：
     文件：${_file#"$SRC/"}
     锚点（整行）：$_anchor
     这块结构变了，需要人工看一眼 scripts/03-target.sh 的这个锚点还成不成立。"

	if [ "$_mode" = "last" ]; then
		_want="$_hits"
	else
		_want=1
	fi

	AF_ANCHOR="$_anchor" AF_SNIP="$_snippet" AF_WANT="$_want" \
	AF_B="$(mark_begin "$_tag")" AF_E="$(mark_end "$_tag")" \
	awk '
		BEGIN { a = ENVIRON["AF_ANCHOR"]; s = ENVIRON["AF_SNIP"]; want = ENVIRON["AF_WANT"] }
		index($0, a) == 1 && length($0) == length(a) {
			seen++
			if (seen == want) {
				print ENVIRON["AF_B"]
				while ((getline l < s) > 0) print l
				close(s)
				print ENVIRON["AF_E"]
			}
		}
		{ print }
	' "$_file" > "$_file.tmp.$$" || { rm -f "$_file.tmp.$$"; die "插入失败：$_what"; }
	mv "$_file.tmp.$$" "$_file"
}

# insert_before_line <file> <整行锚点> <片段> <first|last> <tag> <描述>
insert_before_line() {
	_file="$1"
	_tag="$5"
	_what="$6"

	# 只有一半标记 = 上次写到一半失败了，先清掉这个 tag 的残留再重来。
	if grep -qF "$(mark_begin "$_tag")" "$_file" && ! has_block "$_file" "$_tag"; then
		warn "发现上次写坏的残缺标记（tag=$_tag），先清掉再重来：${_file#"$SRC/"}"
		strip_marked "$_file"
	fi

	if has_block "$_file" "$_tag"; then
		say "  已存在，跳过：$_what"
		return 0
	fi

	_awked_insert "$1" "$2" "$3" "$4" "$_tag" "$_what"

	has_block "$_file" "$_tag" \
		|| die "插入后复查失败：$_what —— 文件里没有成对的标记（tag=$_tag），拒绝继续。"
	say "  已插入：$_what"
}

# append_block <file> <片段> <tag> <描述>
append_block() {
	_file="$1"
	_snippet="$2"
	_tag="$3"
	_what="$4"

	[ -f "$_snippet" ] || die "片段文件不存在：$_snippet"

	if grep -qF "$(mark_begin "$_tag")" "$_file" && ! has_block "$_file" "$_tag"; then
		warn "发现上次写坏的残缺标记（tag=$_tag），先清掉再重来：${_file#"$SRC/"}"
		strip_marked "$_file"
	fi

	if has_block "$_file" "$_tag"; then
		say "  已存在，跳过：$_what"
		return 0
	fi

	{
		printf '\n%s\n' "$(mark_begin "$_tag")"
		cat "$_snippet"
		printf '%s\n' "$(mark_end "$_tag")"
	} >> "$_file"

	has_block "$_file" "$_tag" || die "追加后复查失败：$_what"
	say "  已追加：$_what"
}

# insert_plain_line <file> <整行锚点> <要插的行> <描述>
#
# 不带标记的单行插入。用在 make 的 `\` 续行列表里 —— 那种地方插注释会
# 直接破坏变量定义，所以只能插一行裸内容，靠内容本身唯一来识别。
insert_plain_line() {
	_file="$1"
	_anchor="$2"
	_line="$3"
	_what="$4"

	if grep -qxF "$_line" "$_file"; then
		say "  已存在，跳过：$_what"
		return 0
	fi

	AF_ANCHOR="$_anchor" AF_LINE="$_line" awk '
		BEGIN { a = ENVIRON["AF_ANCHOR"]; l = ENVIRON["AF_LINE"] }
		!done && index($0, a) == 1 && length($0) == length(a) { print l; done = 1 }
		{ print }
	' "$_file" > "$_file.tmp.$$" || { rm -f "$_file.tmp.$$"; die "插入失败：$_what"; }
	mv "$_file.tmp.$$" "$_file"

	grep -qxF "$_line" "$_file" || die "插入后复查失败：$_what（锚点：$_anchor）"
	say "  已插入：$_what"
}

remove_plain_line() {
	_file="$1"
	_line="$2"
	grep -qxF "$_line" "$_file" || return 0
	grep -vxF "$_line" "$_file" > "$_file.tmp.$$"
	mv "$_file.tmp.$$" "$_file"
	say "  已回退：${_file#"$SRC/"}"
}

# ---------------------------------------------------------------------------
# rockchip-armv8 目标
# ---------------------------------------------------------------------------
overlay_rockchip() {
	[ -d "$ROCKCHIP_OVERLAY" ] || die "找不到目标层目录：$ROCKCHIP_OVERLAY"

	KERNEL_PATCH_DIR="$SRC/target/linux/rockchip/patches-6.12"
	UBOOT_PATCH_DIR="$SRC/package/boot/uboot-rockchip/patches"
	ARMV8_MK="$SRC/target/linux/rockchip/image/armv8.mk"
	BOARD_D="$SRC/target/linux/rockchip/armv8/base-files/etc/board.d"
	UBOOT_MK="$SRC/package/boot/uboot-rockchip/Makefile"

	for _d in "$KERNEL_PATCH_DIR" "$UBOOT_PATCH_DIR" "$BOARD_D"; do
		[ -d "$_d" ] || die "目标层要改的目录不存在：${_d#"$SRC/"}
     上游的目录结构变了，需要人工核对 scripts/03-target.sh。"
	done
	[ -f "$ARMV8_MK" ] || die "找不到 $ARMV8_MK"
	[ -f "$UBOOT_MK" ] || die "找不到 $UBOOT_MK"

	# --- 补丁：纯新增文件，直接铺 ---------------------------------------
	#
	# **内容相同就不重写。** 不是为了省一次 cp，而是为了不改 mtime：
	# OpenWrt 的 include/kernel-build.mk 把整个补丁目录列进了
	# KERNEL_FILE_DEPENDS，补丁文件的 mtime 一变就会触发内核重新 prepare。
	# 无条件 cp 的后果是**每次跑 build.sh 都重编一遍内核** ——
	# 十几分钟，而且看起来像「make 的依赖算错了」，很难往这里想。
	install_patch() {
		_src="$1"
		_dst_dir="$2"
		_name="$(basename "$_src")"
		_dst="$_dst_dir/$_name"
		if [ -f "$_dst" ] && cmp -s "$_src" "$_dst"; then
			say "  已是最新：$_name"
		else
			cp "$_src" "$_dst"
			say "  已铺：$_name"
		fi
	}

	for _p in "$ROCKCHIP_OVERLAY"/kernel-patches/*.patch; do
		[ -f "$_p" ] || continue
		install_patch "$_p" "$KERNEL_PATCH_DIR"
	done
	for _p in "$ROCKCHIP_OVERLAY"/uboot-patches/*.patch; do
		[ -f "$_p" ] || continue
		install_patch "$_p" "$UBOOT_PATCH_DIR"
	done

	# 制表符单独取出来。board.d 里 case 分支体是 tab 缩进的，
	# 写死一个字面 tab 在编辑器里看不出来，出问题时也数不清。
	TAB=$(printf '\t')

	# --- 设备定义：armv8.mk 末尾追加 -------------------------------------
	#
	# 追加是安全的：这个文件通篇是 `define Device/... endef` 与
	# `TARGET_DEVICES += ...`，末尾之后没有任何逻辑。
	append_block "$ARMV8_MK" "$ROCKCHIP_OVERLAY/image/armv8.devices.mk" \
		device armv8.mk-设备定义 \
		"armv8.mk 设备定义 hinlink_ht2"

	# --- U-Boot：目标定义 + UBOOT_TARGETS 列表 ---------------------------
	insert_before_line "$UBOOT_MK" 'define U-Boot/radxa-e20c-rk3528' \
		"$ROCKCHIP_OVERLAY/uboot/Makefile.def" first \
		uboot-target-def "uboot-rockchip/Makefile 目标定义"

	# UBOOT_TARGETS 是一个 `\` 续行的 make 变量列表，**不能**插注释，
	# 所以这一处用不带标记的单行插入。锚点是**整行**（含行尾那个反斜杠）。
	insert_plain_line "$UBOOT_MK" '  radxa-e20c-rk3528 \' \
		'  hinlink-ht2-rk3528 \' \
		"uboot-rockchip/Makefile UBOOT_TARGETS"

	# --- board.d：三个 case 分支 -----------------------------------------
	# LED：插在最后一个 esac 之前。这个文件只有一个 esac。
	insert_before_line "$BOARD_D/01_leds" 'esac' \
		"$ROCKCHIP_OVERLAY/base-files/01_leds.case" last \
		leds "01_leds 的 hinlink,ht2 分支"

	# 网口：插在 rockchip_setup_interfaces 的默认分支之前。
	# 全文件只有这一个「tab + *）」，所以用 first 即可。
	insert_before_line "$BOARD_D/02_network" "${TAB}*)" \
		"$ROCKCHIP_OVERLAY/base-files/02_network.interfaces.case" first \
		net-iface "02_network 的网口分支"

	# MAC：插在**最后一个** esac 之前，也就是 rockchip_setup_macs 的收尾。
	# 文件里有两个 esac（interfaces 一个、macs 一个），所以必须用 last ——
	# 用 first 会把分支插到 interfaces 那个 case 里去。
	insert_before_line "$BOARD_D/02_network" "${TAB}esac" \
		"$ROCKCHIP_OVERLAY/base-files/02_network.macs.case" last \
		net-macs "02_network 的 MAC 分支"
}

# ---------------------------------------------------------------------------
# 回退：换目标 / 取消目标时把目标层摘干净
# ---------------------------------------------------------------------------
cleanup_rockchip() {
	KERNEL_PATCH_DIR="$SRC/target/linux/rockchip/patches-6.12"
	UBOOT_PATCH_DIR="$SRC/package/boot/uboot-rockchip/patches"
	ARMV8_MK="$SRC/target/linux/rockchip/image/armv8.mk"
	BOARD_D="$SRC/target/linux/rockchip/armv8/base-files/etc/board.d"
	UBOOT_MK="$SRC/package/boot/uboot-rockchip/Makefile"

	for _p in "$ROCKCHIP_OVERLAY"/kernel-patches/*.patch; do
		[ -f "$_p" ] || continue
		rm -f "$KERNEL_PATCH_DIR/$(basename "$_p")"
	done
	for _p in "$ROCKCHIP_OVERLAY"/uboot-patches/*.patch; do
		[ -f "$_p" ] || continue
		rm -f "$UBOOT_PATCH_DIR/$(basename "$_p")"
	done

	# 注意每一条都要写成 if：`[ -f x ] && cmd` 在 set -e 下，
	# 前半段为假会让整条语句返回非零、脚本直接退出。
	for _f in "$ARMV8_MK" "$BOARD_D/01_leds" "$BOARD_D/02_network" "$UBOOT_MK"; do
		if [ -f "$_f" ]; then
			strip_marked "$_f"
		fi
	done
	if [ -f "$UBOOT_MK" ]; then
		remove_plain_line "$UBOOT_MK" '  hinlink-ht2-rk3528 \'
	fi
}

case "$TARGET" in
	x86_64)
		# x86 没有任何设备层要铺，只要确认上一次留下的 rockchip 层被摘干净。
		cleanup_rockchip
		say "目标 x86_64：不需要设备层补丁"
		;;
	rockchip-armv8)
		say "目标 rockchip-armv8：铺入 HINLINK HT2 设备层"
		overlay_rockchip
		;;
	*)
		die "未知目标：'$TARGET'（只支持 x86_64 / rockchip-armv8）"
		;;
esac

say "目标层就绪（TARGET=$TARGET）"
