#!/bin/sh
#
# 第 2 步：配置并安装 feed。
#
# 做三件事：
#   1. 把 feeds.conf.append 追加到 ImmortalWrt 自带的 feeds.conf.default 后面
#      （istore 只在勾选 iStoreOS 特性时追加）；
#   2. feeds update -a；
#   3. 删掉与 ImmortalWrt 自带包撞名的那一份（mosdns），再 feeds install -a。
#
set -eu
# 自己推导项目根，不依赖调用方 export。
#
# 这些脚本都能单独运行（CI 就是把 09-verify.sh 拆成一个独立 step 调的），
# 而 build.sh 里那句 export 只在经过它时才有效。漏了这两行的后果是
#     ./scripts/09-verify.sh: PROJECT_ROOT: parameter not set
# —— 编译全过、核验步骤直接挂掉。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

. "$PROJECT_ROOT/scripts/lib.sh"

SRC="$PROJECT_ROOT/openwrt"
PRISTINE="$SRC/feeds.conf.immortalwrt"

[ -d "$SRC" ] || die "没找到 $SRC，请先跑 scripts/01-fetch.sh"

# --- 1. 生成 feeds.conf.default --------------------------------------------
# 第一次运行时把 ImmortalWrt 的原件留一份底，之后每次都从它重新拼，
# 这样反复运行不会把 append 内容叠加多次。
[ -f "$PRISTINE" ] || cp "$SRC/feeds.conf.default" "$PRISTINE"
cp "$PRISTINE" "$SRC/feeds.conf.default"

# 兜底过滤：去掉「只有单个 # 的行」。
#
# scripts/feeds 的解析器是 s/#.+$// 再判空，而 `#.+` 要求 # 后面至少还有一个
# 字符 —— 光秃秃一个 `#` 不会被剥掉，会原样进语法检查、报
# "Syntax error in feeds.conf.default, line N"。那个报错的行号指向一行注释，
# 极难联想，所以在这里直接拦掉。
strip_bare_hash() {
	sed '/^#[[:space:]]*$/d'
}

{
	printf '\n'
	printf '# ===== 以下由 immortalwrt-fusion 追加，勿手工编辑 =====\n'
	strip_bare_hash < "$PROJECT_ROOT/feeds.conf.append"
	if [ "$WITH_ISTOREOS" = "1" ]; then
		printf '# iStore 应用商店：只在勾选 iStoreOS 特性时才有意义\n'
		printf 'src-git istore https://github.com/linkease/istore.git;main\n'
	fi
} >> "$SRC/feeds.conf.default"

say "本次启用的 feed："
sed -n 's/^src-[a-z]* \([a-z_0-9]*\).*/  \1/p' "$SRC/feeds.conf.default" | tr '\n' ' '
printf '\n'

# --- 2. update --------------------------------------------------------------
cd "$SRC"
if [ "${SKIP_FEEDS_UPDATE:-0}" = "1" ]; then
	say "SKIP_FEEDS_UPDATE=1，跳过 feeds update"
else
	say "feeds update -a"
	./scripts/feeds update -a
fi

# --- 3a. 例外：mosdns 反过来，由第三方 feed 提供 ---------------------------
#
# 上面那条「第三方让位给底座」的规则有一条例外，而且必须写成例外而不是
# 靠通用规则碰运气 —— 因为这里**二进制与界面必须来自同一家**：
#
#   sbwml 的 luci-app-mosdns 包自带 /etc/init.d/mosdns，
#   而 ImmortalWrt 的 mosdns 包也装同一个文件。
#   一个用底座的二进制 + 第三方的界面，apk 安装时会直接报：
#       ERROR: luci-app-mosdns-1.7.14-r1: trying to overwrite
#              etc/init.d/mosdns owned by mosdns-5.3.3-r1.
#
# 这个错在编译阶段看不出来（两边都编得过），只在 package/install 阶段炸，
# 而且 -j 并行时错误会被淹没，要 -j1 V=s 重跑才看得到 —— 很费时间。
#
# 所以：mosdns 与 luci-app-mosdns **成对**取自 sbwml（5.3.4 + 1.7.14，
# 同一维护者一起维护的配套版本），底座那份 net/mosdns 让位。
#
# 实现顺序很关键：必须在构造 BASE_LIST **之前**删掉底座那份，
# 否则 mosdns 会进 BASE_LIST，紧接着的通用剪枝又把 sbwml 那份剪掉，
# 结果两边都没了。
say "mosdns：改为采用 sbwml 的配套版本（二进制 + 界面成对）"
# PRUNED_ANY 在这里就要初始化：3a 的改动同样需要重建索引，
# 不能等 3b 的循环去初始化它。
PRUNED_ANY=0
if [ -d feeds/packages/net/mosdns ]; then
	rm -rf feeds/packages/net/mosdns
	PRUNED_ANY=1
	say "  已让位：feeds/packages/net/mosdns（底座的 5.3.3）"
fi

# --- 3b. 剪掉与底座撞名的第三方包 -------------------------------------------
#
# **除 mosdns 外，第三方 feed 里的包不允许顶掉底座。**
#
# 两个原因：
#   * 底座（ImmortalWrt 自带的 5 个 feed + 树内 package/）里的版本，是与
#     它自己的构建系统、内核、LuCI 配套的；第三方那份是给别的底座准备的。
#   * 同名包只允许存在一个，两边都在会让构建系统报重复包。
#
# 已知的具体例子：linkease/openwrt-apps 里有 luci-app-cpufreq，底座
# package/emortal 与 feeds/luci 里各有一份，三处重名。
#
# 规则写成通用的而不是逐个点名：上游哪天新增了重名包，也是自动让位给底座，
# 而不是在 defconfig 阶段以很难懂的形式炸掉。
say "剪掉第三方 feed 里与底座撞名的包"
BASE_LIST=$(mktemp)
{
	for d in packages luci routing telephony video; do
		[ -d "feeds/$d" ] || continue
		find "feeds/$d" -mindepth 1 -maxdepth 4 -name Makefile -printf '%h\n' 2>/dev/null \
			| xargs -r -n1 basename
	done
	find package -mindepth 1 -maxdepth 3 -name Makefile -not -path 'package/feeds/*' \
		-printf '%h\n' 2>/dev/null | xargs -r -n1 basename
} | sort -u > "$BASE_LIST"

# PRUNED_ANY 已在 3a 初始化
for f in mosdns nas nas_luci istoreapps istore; do
	[ -d "feeds/$f" ] || continue
	# 先收集再处理：find 一边删一边遍历同一个目录树不可靠。
	PKG_DIRS=$(find "feeds/$f" -mindepth 1 -maxdepth 4 -name Makefile -printf '%h\n' 2>/dev/null)
	for d in $PKG_DIRS; do
		n=$(basename "$d")
		# 只把**真正定义包的**目录当成包目录。像 luci-lib-mac-vendor/src
		# 这种子目录里也有 Makefile，但它是编译单元不是包，剪掉会把包弄坏。
		grep -qE '(BuildPackage|KernelPackage|define +Package/)' "$d/Makefile" 2>/dev/null || continue
		grep -qx "$n" "$BASE_LIST" || continue
		rm -rf "$d"
		printf '  剪掉 [%s] %s\n' "$f" "$n"
		PRUNED_ANY=1
	done
done
rm -f "$BASE_LIST"

# 上一轮 install 留下的断链也要清掉。
#
# package/feeds/<feed>/<pkg> 是指向 feeds/<feed>/.../<pkg> 的软链接。
# 剪掉源目录之后，这些链接就成了断链，而断链会在构建系统扫 package/ 时
# 以 "No such file or directory" 的形式报出来，指向一个看起来存在、
# 实际打不开的路径。只在重复运行时才会出现，最难查。
for f in packages mosdns nas nas_luci istoreapps istore; do
	[ -d "package/feeds/$f" ] || continue
	for link in "package/feeds/$f"/*; do
		[ -e "$link" ] || { rm -rf "$link"; printf '  清掉断链 %s\n' "$link"; }
	done
done

# 剪完之后**必须重建被改动 feed 的索引**。
#
# feeds install 是照 feeds/<name>.index 装的，不是现扫目录。索引还是改动前
# 生成的那一份，install 就会去装已经被删掉的路径 —— 报错信息指向一个根本
# 不存在的目录，很难联想到是「索引没更新」。
#
# `-i` 是「只重建索引、不拉 git」，正合适；顺带把 .tmp 清掉，
# 避免残留的逐包信息混进新索引。
#
# ⚠️ packages 也要重建：3a 从它里面删掉了 net/mosdns。
#    漏了的话 feeds install 会照旧索引去装一个已删除的 mosdns，
#    结果是断链，或者更糟 —— 底座的 mosdns 又回来了，撞文件问题照旧。
if [ "$PRUNED_ANY" = "1" ]; then
	for f in packages mosdns nas nas_luci istoreapps istore; do
		[ -d "feeds/$f" ] || continue
		rm -rf "feeds/$f.tmp" "feeds/$f.index" "feeds/$f.targetindex"
	done
	say "重建被改动 feed 的索引"
	./scripts/feeds update -i packages mosdns nas nas_luci istoreapps istore
fi

say "feeds install -a"
./scripts/feeds install -a

# --- 收尾自检 ---------------------------------------------------------------
# 撞名如果没解除干净，会在 make defconfig 阶段以很难懂的形式报出来。
# 这里提前扫一遍，把「同名包出现在多个 feed 里」直接点名。
say "检查 feed 之间的同名包"
DUP=$(find feeds -mindepth 2 -maxdepth 4 -name Makefile -not -path '*/.git/*' -printf '%h\n' 2>/dev/null \
	| xargs -r -n1 basename | sort | uniq -d)
if [ -n "$DUP" ]; then
	warn "以下包名在多个 feed 目录里重复出现（可能引发重复包错误）："
	printf '  %s\n' $DUP >&2
	warn "如果构建在 defconfig 或 package/compile 阶段报重复包，从这里查起。"
fi

say "feed 准备完成"
